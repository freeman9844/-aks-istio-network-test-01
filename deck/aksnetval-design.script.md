# 발표 스크립트 — AKS 네트워크 통제 검증 샘플 설계

3장 · L300 · 예상 5분 32초

## 1. 검증 샘플 구성 — NSG · Istio · NetworkPolicy
_2분 08초 · 925자_

이번 장표는 설계 문서의 샘플 구성을 한 장에 그린 그림입니다. 목적은 성능이 아니라, PRD 장표에 적힌 NSG, Istio AuthorizationPolicy, NetworkPolicy 규칙이 AKS에서 정말 의도대로 허용하고 차단하는지 확인하는 거예요.
바깥 초록 점선이 VNet 10.50.0.0/16이고, 장표의 예시 CIDR을 그대로 썼습니다. 왼쪽에는 출발지 VM 두 대가 있습니다. snet-appgw-sim의 VM-allow는 App Gateway를 대신하는 허용 출발지이고, snet-other의 VM-deny는 그 밖의 출발지라서 막혀야 합니다. 두 VM 모두 공인 IP 없이 run-command로 curl을 실행합니다.
위쪽 snet-ingress에는 Istio 내부 LB IP 10.50.1.10이 있습니다. 여기 NSG에 일부러 VM-allow를 막는 Deny 규칙을 넣었는데요, LB IP 서브넷의 NSG는 실제로 평가되지 않기 때문에 T1이 그대로 200이면 이 사실까지 증명됩니다. 실제 허용과 차단은 노드 서브넷 snet-aks-app의 NSG에서 100번 Allow, 110번 Deny로 걸립니다.
노드 풀은 시스템 풀 하나와 영역별 사용자 풀 세 개입니다. Istio Ingress Gateway는 기본 동작대로 시스템 노드에 둡니다. Gateway는 Host 이름으로 web-a, web-b에 나눠 보내고, web 네임스페이스의 AuthorizationPolicy가 Gateway의 SA만 받도록 합니다. 그래서 web-a가 web-b를 직접 부르면 403, T9입니다.
web에서 app으로는 자기 BFF만 허용합니다. web-a에서 bff-a는 T4, web-b에서 bff-b는 T6으로 성공하고, 교차 호출은 403이 나와야 합니다. 사이드카가 없는 probe는 STRICT mTLS 때문에 호출 자체가 실패하는 T8입니다.
오른쪽 snet-pe는 Tier 3 데이터를 대표하는 Blob Private Endpoint입니다. web 네임스페이스는 NetworkPolicy로 이 대역을 막아 T10이 실패해야 하고, app 네임스페이스는 정책이 없으니 T11이 성공해야 합니다. 아래쪽 scale 네임스페이스는 HPA와 영역 균형을 보는 곳인데, 다음 장에서 전체 검증 목록부터 보겠습니다.

> 출처: 설계 문서: docs/superpowers/specs/2026-11-19-aks-network-control-validation-design.md
https://learn.microsoft.com/azure/aks/istio-deploy-ingress
https://learn.microsoft.com/azure/aks/internal-lb


## 2. 검증 매트릭스 — 차단 테스트마다 허용 대조군을 둡니다
_1분 32초 · 604자_

앞 장에서 그림으로 본 경로를 검증 ID 단위로 정리한 표입니다. 스크립트가 이 표의 순서대로 실행하고 PASS, FAIL을 자동으로 판정합니다.
위쪽 T1부터 T3까지는 NSG 영역입니다. T1은 VM-allow에서 Ingress LB로 가서 200이 나와야 하고, T2는 VM-deny에서 같은 대상으로 가서 시간 초과가 나와야 하죠. 그런데 VM 자체가 고장 나도 똑같이 시간 초과가 나오거든요. 그래서 같은 VM에서 PE로 TLS 연결이 되는지 보는 T2c를 대조군으로 붙였습니다. T3는 T1 결과를 다시 쓰는데, snet-ingress에 Deny가 있어도 200이면 LB IP 서브넷 NSG가 효과 없다는 게 증명됩니다.
T4부터 T9까지는 Istio입니다. 자기 BFF는 200, 남의 BFF는 403, 사이드카가 없는 Pod는 연결 실패, Ingress를 우회한 web 간 호출은 403입니다. 여기서 403이 나오려면 Service 포트 이름이 http여야 해요. 그렇지 않으면 Istio가 TCP로 보고 연결을 끊어 버려서 판정이 어긋납니다.
T10과 T11은 NetworkPolicy입니다. nc로 TCP만 확인하면 사이드카가 연결을 먼저 받아 줘서 막혀도 성공처럼 보입니다. 그래서 실제 TLS 연결이 맺어지는지로 판정합니다.
마지막 T12와 T13은 스케일링 검증인데, 차단 테스트에는 모두 허용 대조군이 있고 대조군이 실패하면 INCONCLUSIVE로 처리한다는 점을 기억해 주세요. 그럼 T12, T13을 다음 장에서 그림으로 보겠습니다.

> 출처: 설계 문서 6장 검증 매트릭스
https://istio.io/latest/docs/ops/configuration/traffic-management/protocol-selection/


## 3. 스케일링 검증 — HPA 축소 속도와 영역 균형
_1분 52초 · 679자_

앞 장 표의 마지막 두 줄, T12와 T13을 그림으로 풀어 본 장표입니다. 둘 다 시간이 10분에서 15분쯤 걸려서 따로 실행할 수 있게 해 뒀어요.
왼쪽 HPA부터 보겠습니다. hpa-demo를 최소 5, 최대 5로 띄워 두고, minReplicas를 2로 패치합니다. 부하 없이 유휴 상태라 HPA는 2개까지 줄이려 하는데, behavior에 Pods 1개, 60초 정책을 걸어 두었기 때문에 한 번에 1개씩만 줄어야 하거든요. 그래서 막대가 5, 4, 3, 2로 내려가고 각 간격이 55초 이상이면 PASS입니다. 스크립트는 5초 간격으로 replicas와 시각을 기록합니다.
여기서 주의할 점이 두 가지 있어요. 하나는 안정화 창 300초는 이번 검증 범위가 아니라는 겁니다. 패치 직후에 바로 축소가 시작될 수 있어서, 이 결과를 안정화 동작의 근거로 쓰시면 안 됩니다. 다른 하나는 PDB가 HPA 축소에는 적용되지 않는다는 점이죠. PDB는 드레인 같은 eviction에만 동작합니다.
오른쪽은 영역 균형입니다. 영역 1, 2, 3에 사용자 풀을 하나씩 두고 각각 1대에서 3대로 오토스케일합니다. zone-fill Pod는 하나가 노드 한 대를 차지하도록 requests를 잡고, 분산 제약은 일부러 넣지 않습니다. 그래야 스케줄러가 아니라 CAS의 balance-similar-node-groups 효과를 볼 수 있거든요. 노드 6대로 늘어났을 때 영역별 차이가 1 이하면 PASS입니다.
축소할 때의 영역 분포는 공식적으로 보장되는 동작이 아니라서 관찰만 하고, 영역 레이블이 다른 풀을 유사 그룹으로 인식하는지는 PoC로 확인이 필요합니다. 이렇게 세 장이 설계 문서의 전체 범위이고, 승인되면 이 구성 그대로 스크립트와 매니페스트를 만들게 됩니다.

> 출처: https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/#configurable-scaling-behavior
https://learn.microsoft.com/azure/aks/cluster-autoscaler
