# 실측 증적

2026-11-19 koreacentral 클러스터에서 `03-verify.ps1`을 실행한 원본 결과입니다. 파일 이름은 `<순서>-<의미>_<실행 시각>`이며, 각 실행마다 `.md`(표)와 `.json`(기계 판독용)이 있습니다.

| 순서 | 파일 | 범위 | 결과 |
|---|---|---|---|
| 01 | `01-network-baseline_20261119-183104` | T1~T11 | 12건 PASS |
| 02 | `02-network-netpol-removed_20261119-183316` | T1~T11, NetworkPolicy `deny-web-to-data` 삭제 | **T10만 FAIL**(400). 부정 검증 |
| 03 | `03-network-netpol-reapplied_20261119-183538` | T1~T11, 정책 재적용 | 12건 PASS |
| 04 | `04-network-rerun_20261119-184233` | T1~T11 | 12건 PASS |
| 05 | `05-hpa-only_20261119-184952` | T12 | PASS, 간격 60.4초·59.7초 |
| 06 | `06-zone-1200m-saturated_20261119-185218` | T13, `zone-fill` 1200m | 3/3/3. 모든 풀이 최대치라 균형 근거로 쓰지 않음 |
| 07 | `07-zone-800m_20261119-190729` | T13, `zone-fill` 800m | 3/2/2 PASS |
| 08 | `08-final-full-run_20261119-192119` | T1~T13 전체 | **14건 PASS** |

## logs/

| 파일 | 내용 |
|---|---|
| `02-apply.log`, `02-apply-rerun.log` | `02-apply.ps1` 실행 로그 |
| `20-istio.rendered.yaml` | Istio 리비전을 채운 뒤 실제 적용한 매니페스트 |
| `run-hpa.log` | 05 실행 로그 |
| `run-zone.log`, `run-zone2.log` | 06, 07 실행 로그 |
| `run-all.log` | 08 최종 전체 실행 로그(HPA 감소 시각과 노드 증가 추이 포함) |

로컬 경로는 `<repo>`로, Storage 계정 이름은 `staksnetval<hash>`로 마스킹했습니다. 리소스 그룹은 검증 후 삭제했습니다.
