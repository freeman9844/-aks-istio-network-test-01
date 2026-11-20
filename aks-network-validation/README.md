# AKS 네트워크 통제·HPA 축소·영역 균형 검증

샘플 AKS 클러스터(koreacentral)를 만들어 다음을 실제로 검증한다.

- 네트워크 통제(T1~T11): NSG, Istio(`AuthorizationPolicy`, STRICT mTLS), Cilium `NetworkPolicy`, Blob Private Endpoint
- HPA 축소 속도(T12): `scaleDown` 정책 Pods 1 / 60s
- 영역 균형(T13): Cluster Autoscaler `balance-similar-node-groups=true`, 영역별 사용자 풀 `userz1`/`userz2`/`userz3`
- PRD 권장 YAML 반영(v2): 영역 강제 분산 `DoNotSchedule` + `minDomains: 3` 과 CAS 확장(T13b), HPA 축소 후 영역 분포 관찰(T12b)과 `minReplicas: 3` 축소 뒤 영역 하한(T12c, v3), STRICT mTLS 에서 readinessProbe rewrite(T14), `hpa-demo` 의 `replicas` 생략

설계: `docs/superpowers/specs/2026-11-19-aks-network-control-validation-design.md`

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
./03-verify.ps1           # T1~T14 전체. 약 20~45분
./04-cleanup.ps1          # 리소스 그룹 삭제(이름 입력 확인)
```

- 모든 스크립트는 `[-ResourceGroup <이름>]` 을 받는다. 이름·주소는 `config.ps1` 의 `$Cfg` 에만 있다.
- `01-infra.ps1` 은 이미 있는 리소스를 건너뛰므로 다시 실행해도 된다.
- `02`·`03` 은 전용 kubeconfig `results/.kubeconfig` 만 쓰고 현재 kubectl 컨텍스트는 바꾸지 않는다.
- 일부만 검증: `./03-verify.ps1 -Only Network|Hpa|Floor|Zone|Spread` (기본 `All`)

| 구간 | 실측 소요 |
|---|---|
| `-Only Network` (T1~T11, T14) | 약 2.5분 (VM run-command 1회 30~40초) |
| `-Only Hpa` (T12, T12b) | 약 3~8분 (5 → 2, 1분에 1개. 첫 감소까지 최대 약 4분) |
| `-Only Floor` (T12c) | 약 6~10분 (5 → 3 축소를 3회 반복) |
| `-Only Zone` (T13) | 약 2분 + 시작 전 노드가 풀마다 1대로 줄 때까지 대기(최대 25분, 직전 Zone 실행 뒤 약 13분) |
| `-Only Spread` (T13b) | 약 2분 + 같은 대기(전체 실행에서는 T13 뒤 약 12분 대기) |

### 실행 순서 주의

- `02-apply.ps1` 을 다시 실행하면 HPA `hpa-demo` 의 `minReplicas` 가 5 로 돌아간다. T12 는 apply 가 끝난 상태(min 5, replicas 5)를 전제로 한다. `03-verify.ps1` 은 T12 시작 시 min 5 를 다시 맞추고 `finally` 에서 min 5 로 복원하지만, apply 를 먼저 실행해 두어야 한다.
- T13·T13b 는 `finally` 에서 `zone-fill`·`zone-spread` 를 0 으로 되돌린다. 이후 CAS 축소로 노드가 1/1/1 로 돌아가는 데 10분 이상 걸린다. 바로 다시 Zone·Spread 를 실행하면 그동안 대기한다.
- `hpa-demo` 는 `replicas` 를 두지 않는다(HPA 가 소유). apply 직후 1개로 시작해 HPA 가 5개로 늘리며, T12 는 5개 Ready 를 최대 5분 기다린다.

## 결과

- `results/<yyyyMMdd-HHmmss>.json`, `results/<yyyyMMdd-HHmmss>.md`: 열 `Id, From, To, Expect, Observed, Verdict, Note`
- `results/` 와 kubeconfig 는 커밋하지 않는다(`.gitignore`). `04-cleanup.ps1` 은 `results/.kubeconfig` 만 지우고 결과 파일은 남긴다.

판정은 `PASS`, `FAIL`, `INCONCLUSIVE` 세 가지이고, 관찰만 하는 T12b 는 `INFO` 다.

- T3 은 `nsg-ingress` 의 `deny-appgw-all` 규칙이 Deny 로 있고 `snet-ingress` 의 `networkSecurityGroup.id` 가 `nsg-ingress` 로 끝날 때만 T1 판정을 재사용한다. 하나라도 확인되지 않거나 az 조회가 실패하면 `INCONCLUSIVE`.
- 대조군(T1, T2c, T4, T6, T11)이 PASS 가 아니면 해당 차단 테스트는 `INCONCLUSIVE` (Note 에 `대조군 실패: ...`).
- 차단 기대(`000`) 행은 curl 이 실제로 실행됐을 때만 판정한다(Note `curl rc=<n>`, 예: 28 timeout, 56 reset).
- Blob FQDN 이 사설 IP(`snet-pe`)가 아니라 공인 IP 로 해석되면 T10/T11 은 `INCONCLUSIVE` (Note `DNS=<IP>`).
- T12: 샘플 값이 1씩만 줄고(같은 값 반복 허용, 예: 5,5,4,4,3,2) 감소 간격이 모두 55초 이상(60초 정책, 샘플 오차 허용)이면 PASS. 5 → 3 같은 2단계 감소는 FAIL.
- T13: 사용자 노드의 영역별 개수 max − min ≤ 1 이고 Pending Pod 가 없으면 PASS. Pending 이 남으면 확장 여부와 관계없이 FAIL(사유 `Pending Pod가 N개 남아 있습니다`, 할당량 부족 등). Pending 이 없는데 확장 후 사용자 노드 총수가 확장 전보다 늘지 않으면 `INCONCLUSIVE`(사유 `CAS 확장 없음`). 시작 전 풀마다 1대로 25분 안에 돌아오지 않거나 CAS 설정·풀 영역이 다르면 `INCONCLUSIVE`.
- T12b: 축소 전(5개)과 축소 후(2개) `hpa-demo` Pod 의 영역 분포를 기록만 한다(`INFO`). Pod 2개·영역 3개라 빈 영역 1개는 당연하므로 판정 근거로 쓰지 않는다.
- T12c: `minReplicas` 를 5 → 3(영역 수)으로 낮추는 축소를 3회 반복해, 매회 Running 3개가 세 영역에 1개 이상씩 있으면 PASS. 한 회라도 빈 영역이 있으면 FAIL, Running 이 3개가 아니면 `INCONCLUSIVE`.
- T13b: 노드 1/1/1 에서 `zone-spread`(DoNotSchedule, `minDomains: 3`, `nodeTaintsPolicy: Honor`, CPU 800m) 를 6개로 늘려 15분 안에 Pending 없이 영역별 Pod 수 차이 ≤ 1 이면 PASS. Pending 이 남으면 FAIL, Running 합계가 6이 아니면 `INCONCLUSIVE`.
- T14: `web-a`/`web-b`/`bff-a`/`bff-b` Pod 의 app 컨테이너 readinessProbe 가 `15020` `/app-health/...` 로 rewrite 되고 모두 Ready 면 PASS. probe 없음·rewrite 없음·Not Ready 중 하나라도 있으면 FAIL.

실측 v3(T12c 추가, 전체 실행 `results/20261120-100357.*` + T12c 재실행 `results/20261120-100846.*`): 17/17 PASS + INFO 1.

| Id | 결과 |
|---|---|
| T1~T11 | 모두 PASS (T2 `rc=28`, T8 `rc=56`, T10 `DNS=10.50.2.4`) |
| T12 | 5,4,3,2, 간격 59초·64초 → PASS (패치 후 첫 감소 229초, 판정 외) |
| T12b | 축소 전 2/1/2 → 축소 후 1/0/1 → INFO (Pod 2개라 빈 영역 1개는 필연) |
| T12c | 1회 2/1/2→**1/1/1**, 2회 1/2/2→**1/1/1**, 3회 1/2/2→**1/1/1** → PASS |
| T13 | 1/1/1 → 2/2/2 (TriggeredScaleUp `userz1/2/3 1->2`), 6/6 Running 128초 → PASS |
| T13b | 노드 1/1/1 → 2/2/2, Pod 2/2/2, 6/6 Running 132초, 이벤트에 세 풀 모두 기록 → PASS |
| T14 | Ready 4/4, rewrite 4/4 → PASS |

전체 실행에서 T12c 는 문자열 `"$n회"` 를 PowerShell 이 변수 `$n회` 로 해석해 StrictMode 오류(`INCONCLUSIVE`)가 났다. `"${n}회"` 로 고친 뒤 같은 클러스터에서 `-Only Floor` 로 다시 실행했다.

실측 v2(권장 YAML 반영, 전체 실행 `results/20261119-233942.*`): 16/16 PASS + INFO 1.

| Id | 결과 |
|---|---|
| T1~T11 | 모두 PASS (T2 `rc=28`, T8 `rc=56`, T10 `DNS=10.50.2.4`) |
| T12 | 5,4,3,2, 간격 63초·57초 → PASS |
| T12b | 축소 전 2/2/1 → 축소 후 1/0/1 → INFO |
| T13 | 시작 1/1/1 → 2/2/2 (TriggeredScaleUp `userz1/2/3 1->2`), 6/6 Running 125초 → PASS |
| T13b | 노드 1/1/1 → 2/2/2, Pod **2/2/2**, 6/6 Running 110초, Pending 없음 → PASS |
| T14 | Ready 4/4, rewrite 4/4 (`15020 /app-health/app/readyz`) → PASS |

실측 v1(`results/20261119-192119.*`, 권장 YAML 반영 전): 14/14 PASS. T12 간격 61.1초·59.9초, T13 1/1/1 → 3/2/2.

### 해석 시 주의

1. **T12 는 축소 속도 정책(Pods 1 / 60s)만 검증한다.** 안정화 창(300초)은 검증하지 않는다. 패치 후 첫 감소까지 실행마다 6~229초로 달랐다. 이 값을 PRD 의 안정화 동작 근거로 쓰지 말 것.
2. **T13 은 확장만 판정하고 축소는 관찰만 한다.** `zone-fill` 을 0 으로 되돌린 뒤의 CAS 축소는 기다리거나 판정하지 않는다.
3. **영역 레이블이 다른 풀을 CAS 가 유사 노드 그룹으로 보는지**는 문서로 단정하지 않고 이 샘플 결과(한 번의 scale-up 이 세 풀에 나뉨, 3/2/2)로 확인한다. 영역별 정확한 개수는 기존 Pod 배치에 따라 달라진다(예: 2/2/2 또는 3/2/2).
4. **T12b 의 1/0/1 은 발견이 아니다.** Pod 2개를 세 영역에 두면 한 영역은 반드시 비고, 차이 1 은 `maxSkew: 1` 도 만족한다. 그래서 영역 하한은 T12c 로 따로 확인한다. T12c 는 `minReplicas: 3` 으로 3회 축소해 매번 1/1/1 이었다. `topologySpreadConstraints` 는 배치 때만 적용되므로, 이 결과는 ReplicaSet 축소 규칙(같은 노드에 몰린 Pod·최근 생성 Pod 를 먼저 삭제)이 확장 때 추가된 Pod 를 지운 결과로 해석한다(추정). 보장된 동작은 아니며 노드 장애 등으로 분포가 틀어진 뒤의 재분산은 Descheduler 검토가 필요하다(PoC 필요).
5. **T13b 의 TriggeredScaleUp 이벤트는 실행마다 다르다.** v2 에는 `userz3 1->2` 만, v3 에는 세 풀이 모두 남았고 노드는 두 번 모두 1/1/1 → 2/2/2 로 늘었다. 이벤트는 Pod 별로 중복 제거되어 일부만 보일 수 있으므로 판정은 노드·Pod 수로만 한다. CAS 가 Pending Pod 의 분산 제약을 시뮬레이션해 Pod 가 들어갈 영역의 풀을 늘렸다고 해석한다.
6. **시스템 노드 1대는 검증 전용 구성이다.** 가용성이 없다. PRD 에서는 Ingress Gateway 용 전용 `ingress` 풀을 두는 구성을 권장한다.

## 알려진 한계

- curl 래퍼는 실패 시 `'000'` 을 돌려준다. exec/run-command 실패(출력에 `rc=` 줄 없음)와 curl 없음·실행 불가(`rc=127`/`126`)는 차단이 아니라 `INCONCLUSIVE` 로 처리한다.
- T2c 는 Blob FQDN 으로 접속하며 VM 에서 해석된 IP 는 기록하지 않는다.
- T3 은 Deny 규칙(access)과 서브넷 연결만 확인한다. 규칙의 우선순위·주소 범위나 더 높은 우선순위의 Allow 규칙 유무는 확인하지 않는다.
- 모든 풀이 최대(3/3/3)에 닿아도 T13 은 PASS 이고 Note 에 경고만 남긴다. 이때는 균형 근거가 되지 못한다(그래서 `zone-fill` CPU 요청을 1200m 이 아닌 800m 으로 둠).
- HPA 샘플은 5초 간격이라 감소 간격은 최대 +5초 오차가 있다.
- `01-infra.ps1` 은 이미 있는 리소스의 설정 차이(drift)를 맞추지 않는다. 사전 점검은 VM 의 `Standard BSv2 Family` 할당량을 확인하지 않는다(Total Regional vCPUs 에는 포함).
- T14 는 rewrite 된 probe 경로가 Ready 를 만든다는 것만 확인한다. 앱 `/` 응답 실패 시 NotReady 로 바뀌는 음성 시나리오는 검증하지 않는다.
- T13·T13b 의 TriggeredScaleUp·Pending 사유 이벤트는 보조 근거다. 조회에 실패하면 판정은 그대로 두고 Note 에 `이벤트 조회 실패` 를 남긴다.
- Windows 의 PowerShell 7 에서만 확인했다.

## 정리

```powershell
./04-cleanup.ps1                 # 구독·리소스 그룹 이름 출력 후 이름을 그대로 입력해야 삭제
./04-cleanup.ps1 -Force          # 입력 확인 생략(비대화형). 명시했을 때만 생략
az group exists -n rg-aksnetval-krc   # AKS 포함 삭제는 최대 약 1시간. false 가 된 뒤에 01 재실행
```

`az group delete --yes --no-wait` 로 삭제를 요청하고 `results/.kubeconfig` 를 지운다. 다른 리소스 그룹은 건드리지 않는다.
