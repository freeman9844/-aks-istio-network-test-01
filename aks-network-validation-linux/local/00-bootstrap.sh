#!/usr/bin/env bash
# 로컬 실행: 00-bootstrap.sh [--force]
# 사전 점검 → RG → VNet·snet-mgmt → NAT Gateway → vm-mgmt(공인 IP 없음, 시스템 할당 MI) → 역할 2개 → 도구 설치.
# 모든 단계는 이미 있으면 건너뛴다. 사전 점검에서 문제가 있으면 아무것도 만들지 않고 끝낸다.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=../config.sh
source "$ROOT/config.sh"
# shellcheck source=../vm/lib/common.sh
source "$ROOT/vm/lib/common.sh"
# shellcheck source=lib/vmexec.sh
source "$HERE/lib/vmexec.sh"

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1
AZ="${AZ:-az}"
NETWORK_CONTRIBUTOR_ID="4d97b98b-1d4f-4787-a291-c67834d212e7"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. 구독 확인
sub_name="$(az_ok account show --query name -o tsv)"
log "현재 구독: $sub_name / 리소스 그룹: $RG ($LOCATION)"
if (( ! FORCE )); then
  read -r -p "이 구독에 리소스를 만들까요? (y/N) " answer
  [[ "$answer" == y ]] || { log "중단: 아무것도 만들지 않았습니다"; exit 1; }
fi

# 2. 공개 AKS 확인 + 사전 점검(관리 ID 는 구독 범위 조회를 못 하므로 로컬에서 한다)
own_dsv5=0
if exists aks show -g "$RG" -n "$AKS"; then
  priv="$(az_ok aks show -g "$RG" -n "$AKS" --query apiServerAccessProfile.enablePrivateCluster -o tsv)"
  aks_private_guard "$priv" || die "$RG 의 $AKS 가 Private Cluster 가 아닙니다(공개→비공개 제자리 전환 불가). 다른 RG(AKSNETVAL_RG)를 쓰거나 정리 후 다시 실행하세요"
  pools="$(az_ok aks nodepool list -g "$RG" --cluster-name "$AKS" --query "[].[vmSize, count]" -o tsv | tr -d '\r')"
  while read -r size count; do
    case "$size" in
      Standard_D4s_v5) own_dsv5=$(( own_dsv5 + 4 * count )) ;;
      Standard_D2s_v5) own_dsv5=$(( own_dsv5 + 2 * count )) ;;
    esac
  done <<<"$pools"
fi
own_vms=0
for vm in "$VM_APPGW" "$VM_OTHER" "$VM_MGMT"; do
  exists vm show -g "$RG" -n "$vm" && own_vms=$(( own_vms + 1 ))
done
log "사전 점검: 할당량·SKU 조회"
az_ok vm list-usage -l "$LOCATION" -o json > "$WORK/usage.json"
az_ok vm list-skus -l "$LOCATION" --resource-type virtualMachines --size Standard_D -o json > "$WORK/skus-d.json"
az_ok vm list-skus -l "$LOCATION" --resource-type virtualMachines --size "$VM_SIZE" -o json > "$WORK/skus-b.json"
python3 -c 'import json,sys; json.dump(json.load(open(sys.argv[1])) + json.load(open(sys.argv[2])), open(sys.argv[3], "w"))' \
  "$WORK/skus-d.json" "$WORK/skus-b.json" "$WORK/skus.json"
if ! found="$(cd "$ROOT" && python3 -m aksnetval.preflight "$WORK/usage.json" "$WORK/skus.json" "$own_dsv5" "$own_vms" \
  "$SYSTEM_VM_SIZE" "$USER_VM_SIZE" "$VM_SIZE")"; then
  die "사전 점검 실패: $(echo "$found" | paste -sd ';' -)"
fi
log "사전 점검 통과"

# 3. RG
if [[ "$(az_ok group exists -n "$RG")" == true ]]; then
  log "RG $RG 있음: 건너뜀"
else
  az_ok group create -n "$RG" -l "$LOCATION" --tags "$TAGS" -o none
  log "RG $RG 생성"
fi

# 4. VNet + snet-mgmt
if exists network vnet show -g "$RG" -n "$VNET"; then
  log "VNet $VNET 있음: 건너뜀"
else
  az_ok network vnet create -g "$RG" -n "$VNET" -l "$LOCATION" --address-prefixes "$VNET_PREFIX" --tags "$TAGS" -o none
  log "VNet $VNET 생성"
fi

# 5. NAT Gateway(snet-mgmt 전용 아웃바운드: 도구 설치와 run-command 결과 반환)
if ! exists network public-ip show -g "$RG" -n "$PIP_NAT_MGMT"; then
  az_ok network public-ip create -g "$RG" -n "$PIP_NAT_MGMT" -l "$LOCATION" --sku Standard --allocation-method Static --tags "$TAGS" -o none
  log "공인 IP $PIP_NAT_MGMT 생성"
fi
if ! exists network nat gateway show -g "$RG" -n "$NAT_MGMT"; then
  az_ok network nat gateway create -g "$RG" -n "$NAT_MGMT" -l "$LOCATION" --public-ip-addresses "$PIP_NAT_MGMT" --idle-timeout 4 --tags "$TAGS" -o none
  log "NAT Gateway $NAT_MGMT 생성"
fi
if exists network vnet subnet show -g "$RG" --vnet-name "$VNET" -n "$SNET_MGMT_NAME"; then
  az_ok network vnet subnet update -g "$RG" --vnet-name "$VNET" -n "$SNET_MGMT_NAME" --nat-gateway "$NAT_MGMT" -o none
  log "서브넷 $SNET_MGMT_NAME 있음: NAT Gateway 연결 확인"
else
  az_ok network vnet subnet create -g "$RG" --vnet-name "$VNET" -n "$SNET_MGMT_NAME" --address-prefixes "$SNET_MGMT_PREFIX" --nat-gateway "$NAT_MGMT" -o none
  log "서브넷 $SNET_MGMT_NAME 생성(NAT Gateway 연결)"
fi

# 6. vm-mgmt(공인 IP·NSG 없음). 인바운드 접속을 쓰지 않으므로 SSH 키는 일회용으로 만들고 버린다
if exists vm show -g "$RG" -n "$VM_MGMT"; then
  log "VM $VM_MGMT 있음: 건너뜀"
else
  ssh-keygen -t rsa -b 4096 -N '' -q -f "$WORK/key" >/dev/null
  az_ok vm create -g "$RG" -n "$VM_MGMT" -l "$LOCATION" --image Ubuntu2204 --size "$VM_SIZE" \
    --vnet-name "$VNET" --subnet "$SNET_MGMT_NAME" --public-ip-address "" --nsg "" \
    --admin-username azureuser --ssh-key-values "$WORK/key.pub" \
    --assign-identity "[system]" --tags "$TAGS" -o none
  log "VM $VM_MGMT 생성"
fi

# 7. 관리 ID 역할: RG 범위 Contributor + RBAC Administrator(Network Contributor 만 할당·삭제 가능)
principal="$(az_ok vm show -g "$RG" -n "$VM_MGMT" --query identity.principalId -o tsv | tr -d '\r')"
[[ -n "$principal" ]] || die "$VM_MGMT 의 시스템 할당 관리 ID 가 없습니다"
rg_id="$(az_ok group show -n "$RG" --query id -o tsv | tr -d '\r')"
condition="((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$NETWORK_CONTRIBUTOR_ID})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$NETWORK_CONTRIBUTOR_ID}))"
assign_role() {
  local role="$1"
  shift
  local n
  n="$(az_ok role assignment list --role "$role" --scope "$rg_id" --query "[?principalId=='$principal'] | length(@)" -o tsv | tr -d '\r')"
  if [[ "$n" != 0 ]]; then
    log "역할 '$role' 있음: 건너뜀"
    return
  fi
  # 새 관리 ID 는 Entra 복제 지연으로 잠시 찾지 못할 수 있어 재시도한다
  retry 6 20 "$AZ" role assignment create --assignee-object-id "$principal" --assignee-principal-type ServicePrincipal \
    --role "$role" --scope "$rg_id" "$@" -o none || die "역할 '$role' 할당 실패"
  log "역할 '$role' 할당"
}
assign_role "Contributor"
assign_role "Role Based Access Control Administrator" --condition "$condition" --condition-version 2.0

# 8. 도구 설치 + az login --identity(역할 전파 대기 포함). 상세 로그는 VM 의 /var/log/aksnetval-bootstrap.log
log "vm-mgmt 도구 설치(az, kubectl, python3-venv, jq, dnsutils). 수 분 걸립니다"
install_script="set -e
exec 3>&1 >>/var/log/aksnetval-bootstrap.log 2>&1
export DEBIAN_FRONTEND=noninteractive
mkdir -p $(printf '%q' "$VM_ROOT")/state $(printf '%q' "$VM_ROOT")/results $(printf '%q' "$VM_ROOT")/logs
apt-get update -q
apt-get install -y -q python3-venv jq dnsutils curl ca-certificates
command -v az >/dev/null || curl -sL https://aka.ms/InstallAzureCLIDeb | bash
command -v kubectl >/dev/null || az aks install-cli
ok=0
for i in \$(seq 1 20); do
  if az login --identity -o none && az group show -n $(printf '%q' "$RG") -o none; then ok=1; break; fi
  sleep 30
done
[ \$ok = 1 ] || { echo 'az login --identity 또는 RG 조회 실패(역할 전파 대기 초과)' >&3; exit 1; }
echo \"az \$(az version --query '\"azure-cli\"' -o tsv), \$(kubectl version --client 2>/dev/null | head -n 1), \$(python3 --version)\" >&3"
if ! out="$(retry 3 30 vm_exec "$install_script")"; then
  die "vm-mgmt 도구 설치 실패: $out (VM 의 /var/log/aksnetval-bootstrap.log 확인)"
fi
log "도구: $out"
log "부트스트랩 완료. 다음: local/run.sh infra"
