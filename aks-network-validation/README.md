# AKS 네트워크 통제·HPA 축소·영역 균형 검증

샘플 AKS 클러스터(koreacentral)를 만들어 다음을 실제로 검증한다.

- 네트워크 통제(T1~T11): NSG, Istio(`AuthorizationPolicy`, STRICT mTLS), Cilium `NetworkPolicy`, Blob Private Endpoint
- HPA 축소 속도(T12): `scaleDown` 정책 Pods 1 / 60s
- 영역 균형(T13): Cluster Autoscaler `balance-similar-node-groups=true`, 영역별 사용자 풀 `userz1`/`userz2`/`userz3`

설계: [`../docs/design-spec.md`](../docs/design-spec.md) · 구현 계획: [`../docs/implementation-plan.md`](../docs/implementation-plan.md) · 실측 증적: [`../evidence/`](../evidence/)

## 사전 준비

- Windows + PowerShell 7 (`pwsh`)
- Azure CLI 로그인(`az login`) 후 **검증 전용 구독**을 선택(`az account set -s <구독>`)
- kubectl: PATH 에 없으면 `az aks install-cli` (기본 위치 `%USERPROFILE%\.azure-kubectl` 을 스크립트가 자동 추가)
- 단위 테스트용 Pester 5.5 이상: `Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser`

## 리소스와 최대 vCPU

| 항목 | 값 |
|---|---|
| 리전 / 리소스 그룹 | `koreacentral` / `rg-aksnetval-krc` (`-ResourceGroup` 으로 변경) |
| 시스템 풀 `system` | `Standard_D4s_v5` 1대 고정, 영역 1·2·3, taint `CriticalAddonsOnly=true:NoSchedule` |
| 사용자 풀 `userz1`/`userz2`/`userz3` | `Standard_D2s_v5`, 영역 1/2/3, 오토스케일 1~3 |
| 트래픽 출발지 VM `vm-appgw-sim`, `vm-other` | `Standard_B2s_v2` (koreacentral 에 `Standard_B2s` 없음), 공인 IP 없음 |

최대 vCPU(config.ps1 기준): `Standard DSv5 Family` 22 (시스템 4 + 사용자 2 × 3풀 × 최대 3대 18) + `Standard_B2s_v2` 2대 4 = **총 26 vCPU** (Total Regional vCPUs).
사전 점검(`01-infra.ps1`)은 `Standard DSv5 Family` 22 vCPU, Total Regional vCPUs 26(VM 2대 포함, 재실행 시 이미 있는 클러스터·VM 사용분 제외)과 SKU·영역 제한을 확인한다. `Standard BSv2 Family` 할당량은 확인하지 않는다.

## 실행 순서

```powershell
cd aks-network-validation
./01-infra.ps1            # 인프라 생성. 구독 이름 출력 후 y 확인(-Force 로 생략). 약 25분
./02-apply.ps1            # Istio 내부 Gateway 활성화와 매니페스트 적용. 약 5분
./03-verify.ps1           # T1~T13 전체. 약 15~35분
./04-cleanup.ps1          # 리소스 그룹 삭제(이름 입력 확인)
```

- 모든 스크립트는 `[-ResourceGroup <이름>]` 을 받는다. 이름·주소는 `config.ps1` 의 `$Cfg` 에만 있다.
- `01-infra.ps1` 은 이미 있는 리소스를 건너뛰므로 다시 실행해도 된다.
- `02`·`03` 은 전용 kubeconfig `results/.kubeconfig` 만 쓰고 현재 kubectl 컨텍스트는 바꾸지 않는다.
- 일부만 검증: `./03-verify.ps1 -Only Network|Hpa|Zone` (기본 `All`)

| 구간 | 실측 소요 |
|---|---|
| `-Only Network` (T1~T11) | 약 2.5분 (VM run-command 1회 30~40초) |
| `-Only Hpa` (T12) | 약 3~5분 (5 → 2, 1분에 1개) |
| `-Only Zone` (T13) | 약 2분 + 시작 전 노드가 풀마다 1대로 줄 때까지 대기(최대 20분, 직전 Zone 실행 뒤 약 13분) |

### 실행 순서 주의

- `02-apply.ps1` 을 다시 실행하면 HPA `hpa-demo` 의 `minReplicas` 가 5 로 돌아간다. T12 는 apply 가 끝난 상태(min 5, replicas 5)를 전제로 한다. `03-verify.ps1` 은 T12 시작 시 min 5 를 다시 맞추고 `finally` 에서 min 5 로 복원하지만, apply 를 먼저 실행해 두어야 한다.
- T13 은 `finally` 에서 `zone-fill` 을 0 으로 되돌린다. 이후 CAS 축소로 노드가 1/1/1 로 돌아가는 데 10분 이상 걸린다. 바로 다시 Zone 을 실행하면 그동안 대기한다.

## 결과

- `results/<yyyyMMdd-HHmmss>.json`, `results/<yyyyMMdd-HHmmss>.md`: 열 `Id, From, To, Expect, Observed, Verdict, Note`
- `results/` 와 kubeconfig 는 커밋하지 않는다(`.gitignore`). `04-cleanup.ps1` 은 `results/.kubeconfig` 만 지우고 결과 파일은 남긴다.

판정은 `PASS`, `FAIL`, `INCONCLUSIVE` 세 가지다.

- T3 은 `nsg-ingress` 의 `deny-appgw-all` 규칙이 Deny 로 있고 `snet-ingress` 의 `networkSecurityGroup.id` 가 `nsg-ingress` 로 끝날 때만 T1 판정을 재사용한다. 하나라도 확인되지 않거나 az 조회가 실패하면 `INCONCLUSIVE`.
- 대조군(T1, T2c, T4, T6, T11)이 PASS 가 아니면 해당 차단 테스트는 `INCONCLUSIVE` (Note 에 `대조군 실패: ...`).
- 차단 기대(`000`) 행은 curl 이 실제로 실행됐을 때만 판정한다(Note `curl rc=<n>`, 예: 28 timeout, 56 reset).
- Blob FQDN 이 사설 IP(`snet-pe`)가 아니라 공인 IP 로 해석되면 T10/T11 은 `INCONCLUSIVE` (Note `DNS=<IP>`).
- T12: 샘플 값이 1씩만 줄고(같은 값 반복 허용, 예: 5,5,4,4,3,2) 감소 간격이 모두 55초 이상(60초 정책, 샘플 오차 허용)이면 PASS. 5 → 3 같은 2단계 감소는 FAIL.
- T13: 사용자 노드의 영역별 개수 max − min ≤ 1 이고 Pending Pod 가 없으면 PASS. Pending 이 남으면 확장 여부와 관계없이 FAIL(사유 `Pending Pod가 N개 남아 있습니다`, 할당량 부족 등). Pending 이 없는데 확장 후 사용자 노드 총수가 확장 전보다 늘지 않으면 `INCONCLUSIVE`(사유 `CAS 확장 없음`). 시작 전 풀마다 1대로 20분 안에 돌아오지 않거나 CAS 설정·풀 영역이 다르면 `INCONCLUSIVE`.

실측(전체 실행 `results/20261119-192119.*`): 14/14 PASS.

| Id | 결과 |
|---|---|
| T1~T11 | 모두 PASS (T2 `rc=28`, T8 `rc=56`, T10 `DNS=10.50.2.4`) |
| T12 | 5,4,3,2, 간격 61.1초·59.9초 → PASS |
| T13 | 시작 1/1/1 → 3/2/2 (TriggeredScaleUp `userz1 1->3`, `userz2 1->2`, `userz3 1->2`), 6/6 Running 112초 → PASS |

### 해석 시 주의

1. **T12 는 축소 속도 정책(Pods 1 / 60s)만 검증한다.** 안정화 창(300초)은 검증하지 않는다. 패치 후 첫 감소까지 6~16초밖에 걸리지 않았는데, 이 값을 PRD 의 안정화 동작 근거로 쓰지 말 것.
2. **T13 은 확장만 판정하고 축소는 관찰만 한다.** `zone-fill` 을 0 으로 되돌린 뒤의 CAS 축소는 기다리거나 판정하지 않는다.
3. **영역 레이블이 다른 풀을 CAS 가 유사 노드 그룹으로 보는지**는 문서로 단정하지 않고 이 샘플 결과(한 번의 scale-up 이 세 풀에 나뉨, 3/2/2)로 확인한다. 영역별 정확한 개수는 기존 Pod 배치에 따라 달라진다(예: 2/2/2 또는 3/2/2).
4. **시스템 노드 1대는 검증 전용 구성이다.** 가용성이 없다. PRD 에서는 Ingress Gateway 용 전용 `ingress` 풀을 두는 구성을 권장한다.

## 알려진 한계

- curl 래퍼는 실패 시 `'000'` 을 돌려준다. exec/run-command 실패(출력에 `rc=` 줄 없음)와 curl 없음·실행 불가(`rc=127`/`126`)는 차단이 아니라 `INCONCLUSIVE` 로 처리한다.
- T2c 는 Blob FQDN 으로 접속하며 VM 에서 해석된 IP 는 기록하지 않는다.
- T3 은 Deny 규칙(access)과 서브넷 연결만 확인한다. 규칙의 우선순위·주소 범위나 더 높은 우선순위의 Allow 규칙 유무는 확인하지 않는다.
- 모든 풀이 최대(3/3/3)에 닿아도 T13 은 PASS 이고 Note 에 경고만 남긴다. 이때는 균형 근거가 되지 못한다(그래서 `zone-fill` CPU 요청을 1200m 이 아닌 800m 으로 둠).
- HPA 샘플은 5초 간격이라 감소 간격은 최대 +5초 오차가 있다.
- `01-infra.ps1` 은 이미 있는 리소스의 설정 차이(drift)를 맞추지 않는다. 사전 점검은 VM 의 `Standard BSv2 Family` 할당량을 확인하지 않는다(Total Regional vCPUs 에는 포함).
- T13 의 TriggeredScaleUp·Pending 사유 이벤트는 보조 근거다. 조회에 실패하면 판정은 그대로 두고 Note 에 `이벤트 조회 실패` 를 남긴다.
- Windows 의 PowerShell 7 에서만 확인했다.

## 정리

```powershell
./04-cleanup.ps1                 # 구독·리소스 그룹 이름 출력 후 이름을 그대로 입력해야 삭제
./04-cleanup.ps1 -Force          # 입력 확인 생략(비대화형). 명시했을 때만 생략
az group exists -n rg-aksnetval-krc   # AKS 포함 삭제는 최대 약 1시간. false 가 된 뒤에 01 재실행
```

`az group delete --yes --no-wait` 로 삭제를 요청하고 `results/.kubeconfig` 를 지운다. 다른 리소스 그룹은 건드리지 않는다.
