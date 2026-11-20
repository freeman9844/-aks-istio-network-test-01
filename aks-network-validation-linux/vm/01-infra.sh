#!/usr/bin/env bash
# vm-mgmt 에서 실행: 검증용 인프라 생성(기존 01-infra.ps1 이식 + Private Cluster).
# 이미 있는 리소스는 건너뛰므로 다시 실행해도 안전하다. RG·VNet·snet-mgmt·vm-mgmt 는 로컬 00-bootstrap.sh 가 만든다.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/vm/lib/common.sh"
retry 5 20 az login --identity -o none || die "az login --identity 실패"
# shellcheck source=../config.sh
source "$ROOT/config.sh"

# ensure <라벨> <show 인자…> -- <create 인자…>: show 가 성공하면 건너뛰고, 아니면 create 를 실행한다
ensure() {
  local label="$1"
  shift
  local show=() create=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do show+=("$1"); shift; done
  shift
  create=("$@")
  if exists "${show[@]}"; then
    log "이미 있음: $label"
  else
    log "생성: $label"
    az_ok "${create[@]}" -o none
  fi
}

# 0. 공개 AKS 가 남아 있으면 아무것도 바꾸기 전에 중단(공개 → 비공개 제자리 전환 불가)
priv="$(az aks show -g "$RG" -n "$AKS" --query apiServerAccessProfile.enablePrivateCluster -o tsv 2>/dev/null || true)"
aks_private_guard "$priv" || die "$AKS 가 Private Cluster 가 아닙니다(enablePrivateCluster=$priv). 정리 후 다시 실행하세요"

# 1. VNet·서브넷(VNet 과 snet-mgmt 는 부트스트랩이 이미 만듦)
ensure "VNet $VNET" network vnet show -g "$RG" -n "$VNET" -- \
  network vnet create -g "$RG" -n "$VNET" -l "$LOCATION" --address-prefixes "$VNET_PREFIX" --tags "$TAGS"
for key in AKS_APP INGRESS PE APPGW_SIM OTHER; do
  name_var="SNET_${key}_NAME"
  prefix_var="SNET_${key}_PREFIX"
  ensure "서브넷 ${!name_var}" network vnet subnet show -g "$RG" --vnet-name "$VNET" -n "${!name_var}" -- \
    network vnet subnet create -g "$RG" --vnet-name "$VNET" -n "${!name_var}" --address-prefixes "${!prefix_var}"
done

# 2. NSG 2개와 규칙, 서브넷 연결
nsg_rule() {
  # nsg_rule <nsg> <이름> <우선순위> <Allow|Deny> <출발지> <목적지> <프로토콜> <포트>
  ensure "NSG 규칙 $1/$2" network nsg rule show -g "$RG" --nsg-name "$1" -n "$2" -- \
    network nsg rule create -g "$RG" --nsg-name "$1" -n "$2" --priority "$3" --direction Inbound --access "$4" \
    --protocol "$7" --source-address-prefixes "$5" --source-port-ranges '*' \
    --destination-address-prefixes "$6" --destination-port-ranges "$8"
}
nsg_attach() {
  local subnet="$1" nsg="$2" attached
  attached="$(az_ok network vnet subnet show -g "$RG" --vnet-name "$VNET" -n "$subnet" --query networkSecurityGroup.id -o tsv)"
  if [[ "${attached##*/}" == "$nsg" ]]; then
    log "이미 있음: $subnet ← $nsg 연결"
  else
    log "생성: $subnet ← $nsg 연결"
    az_ok network vnet subnet update -g "$RG" --vnet-name "$VNET" -n "$subnet" --network-security-group "$nsg" -o none
  fi
}
for nsg in "$NSG_AKS_APP" "$NSG_INGRESS"; do
  ensure "NSG $nsg" network nsg show -g "$RG" -n "$nsg" -- network nsg create -g "$RG" -n "$nsg" -l "$LOCATION" --tags "$TAGS"
done
nsg_rule "$NSG_AKS_APP" allow-appgw-to-ingress 100 Allow "$SNET_APPGW_SIM_PREFIX" "$INGRESS_IP" Tcp 80
nsg_rule "$NSG_AKS_APP" deny-other-to-ingress 110 Deny "$SNET_OTHER_PREFIX" "$INGRESS_IP" Tcp 80
nsg_attach "$SNET_AKS_APP_NAME" "$NSG_AKS_APP"
nsg_rule "$NSG_INGRESS" "$NSG_INGRESS_DENY_RULE" 100 Deny "$SNET_APPGW_SIM_PREFIX" '*' '*' '*'
nsg_attach "$SNET_INGRESS_NAME" "$NSG_INGRESS"

# 3. 사용자 할당 관리 ID + VNet 에 Network Contributor(vm-mgmt 의 조건부 RBAC Administrator 로 할당)
ensure "관리 ID $IDENTITY" identity show -g "$RG" -n "$IDENTITY" -- identity create -g "$RG" -n "$IDENTITY" -l "$LOCATION" --tags "$TAGS"
id_principal="$(az_ok identity show -g "$RG" -n "$IDENTITY" --query principalId -o tsv)"
id_resource="$(az_ok identity show -g "$RG" -n "$IDENTITY" --query id -o tsv)"
vnet_id="$(az_ok network vnet show -g "$RG" -n "$VNET" --query id -o tsv)"
n="$(az_ok role assignment list --scope "$vnet_id" --role "Network Contributor" --query "[?principalId=='$id_principal'] | length(@)" -o tsv)"
if [[ "$n" != 0 ]]; then
  log "이미 있음: $IDENTITY → VNet Network Contributor"
else
  log "생성: $IDENTITY → VNet Network Contributor (전파 대기 60초)"
  retry 6 20 az role assignment create --assignee-object-id "$id_principal" --assignee-principal-type ServicePrincipal \
    --role "Network Contributor" --scope "$vnet_id" -o none || die "Network Contributor 할당 실패"
  sleep 60
fi

# 4. Storage 2개 + 고정 IP Blob Private Endpoint + 사설 DNS
#    app 네임스페이스 NetworkPolicy 가 PE IP /32 로 허용하므로 IP 를 고정한다(bff-b→STORAGE, bff-a→STORAGE2)
ensure "사설 DNS 영역 $BLOB_DNS_ZONE" network private-dns zone show -g "$RG" -n "$BLOB_DNS_ZONE" -- \
  network private-dns zone create -g "$RG" -n "$BLOB_DNS_ZONE" --tags "$TAGS"
ensure "DNS VNet 링크 $BLOB_DNS_LINK" network private-dns link vnet show -g "$RG" --zone-name "$BLOB_DNS_ZONE" -n "$BLOB_DNS_LINK" -- \
  network private-dns link vnet create -g "$RG" --zone-name "$BLOB_DNS_ZONE" -n "$BLOB_DNS_LINK" \
  --virtual-network "$VNET" --registration-enabled false --tags "$TAGS"
blob_pe() {
  # blob_pe <Storage> <PE 이름> <고정 IP>
  local st="$1" pe="$2" ip="$3" st_id nic got
  ensure "Storage $st" storage account show -g "$RG" -n "$st" -- \
    storage account create -g "$RG" -n "$st" -l "$LOCATION" --kind StorageV2 --sku Standard_LRS \
    --public-network-access Disabled --allow-blob-public-access false --min-tls-version TLS1_2 --tags "$TAGS"
  st_id="$(az_ok storage account show -g "$RG" -n "$st" --query id -o tsv)"
  ensure "Private Endpoint $pe ($ip)" network private-endpoint show -g "$RG" -n "$pe" -- \
    network private-endpoint create -g "$RG" -n "$pe" -l "$LOCATION" --vnet-name "$VNET" --subnet "$SNET_PE_NAME" \
    --private-connection-resource-id "$st_id" --group-id blob --connection-name "$pe-conn" \
    --ip-config "{name:ipc-blob,group-id:blob,member-name:blob,private-ip-address:$ip}" --tags "$TAGS"
  # 예전 실행에서 동적 IP 로 만든 PE 가 남아 있으면 정책과 어긋나므로 중단한다(NIC 의 실제 IP 로 확인)
  nic="$(az_ok network private-endpoint show -g "$RG" -n "$pe" --query 'networkInterfaces[0].id' -o tsv)"
  got="$(az_ok network nic show --ids "$nic" --query 'ipConfigurations[0].privateIPAddress' -o tsv)"
  [[ "$got" == "$ip" ]] || die "$pe 의 IP 가 $got 입니다(기대 $ip). PE 를 지우고 다시 실행하세요"
  ensure "DNS zone group $pe/default" network private-endpoint dns-zone-group show -g "$RG" --endpoint-name "$pe" -n default -- \
    network private-endpoint dns-zone-group create -g "$RG" --endpoint-name "$pe" -n default \
    --private-dns-zone "$BLOB_DNS_ZONE" --zone-name blob
}
blob_pe "$STORAGE" "$BLOB_PE" "$BLOB_PE_IP"
blob_pe "$STORAGE2" "$BLOB2_PE" "$BLOB2_PE_IP"

# 5. 트래픽 출발지 VM 2대(공인 IP·NIC NSG 없음)
for pair in "$VM_APPGW:$SNET_APPGW_SIM_NAME" "$VM_OTHER:$SNET_OTHER_NAME"; do
  vm="${pair%%:*}"
  subnet="${pair#*:}"
  ensure "VM $vm" vm show -g "$RG" -n "$vm" -- \
    vm create -g "$RG" -n "$vm" -l "$LOCATION" --image Ubuntu2204 --size "$VM_SIZE" --vnet-name "$VNET" --subnet "$subnet" \
    --public-ip-address "" --nsg "" --admin-username azureuser --generate-ssh-keys --tags "$TAGS"
done

# 6. AKS(Private Cluster, public FQDN 끔). 그 외 옵션은 기존과 동일
subnet_id="$(az_ok network vnet subnet show -g "$RG" --vnet-name "$VNET" -n "$SNET_AKS_APP_NAME" --query id -o tsv)"
ensure "AKS $AKS (Private Cluster)" aks show -g "$RG" -n "$AKS" -- \
  aks create -g "$RG" -n "$AKS" -l "$LOCATION" \
  --network-plugin azure --network-plugin-mode overlay --network-dataplane cilium \
  --pod-cidr "$POD_CIDR" --vnet-subnet-id "$subnet_id" --assign-identity "$id_resource" \
  --enable-azure-service-mesh --tier free \
  --enable-private-cluster --disable-public-fqdn \
  --nodepool-name system --node-count 1 --node-vm-size "$SYSTEM_VM_SIZE" --zones 1 2 3 \
  --nodepool-taints CriticalAddonsOnly=true:NoSchedule \
  --cluster-autoscaler-profile balance-similar-node-groups=true \
  --tags "$TAGS"

# 7. 영역별 사용자 풀(크기·레이블·taint 동일)
for i in "${!USER_POOLS[@]}"; do
  pool="${USER_POOLS[$i]}"
  zone=$(( i + 1 ))
  ensure "노드 풀 $pool (영역 $zone)" aks nodepool show -g "$RG" --cluster-name "$AKS" -n "$pool" -- \
    aks nodepool add -g "$RG" --cluster-name "$AKS" -n "$pool" --mode User --zones "$zone" \
    --node-vm-size "$USER_VM_SIZE" --vnet-subnet-id "$subnet_id" --node-count "$USER_MIN" \
    --enable-cluster-autoscaler --min-count "$USER_MIN" --max-count "$USER_MAX" --tags "$TAGS"
done

# 8. kubeconfig(Private API 는 vm-mgmt 가 있는 VNet 에서만 닿는다)
az_ok aks get-credentials -g "$RG" -n "$AKS" --file "$VM_ROOT/state/kubeconfig" --overwrite-existing -o none
kube get nodes -o wide || die "kubectl 로 Private API 서버에 접속하지 못했습니다"
log "인프라 준비 완료"
