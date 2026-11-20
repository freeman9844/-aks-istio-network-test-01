"""판정 함수(기존 Verdict.psm1 대응). 모두 순수 함수이고 사유 문구는 원본과 같다."""
import ipaddress
import sys
from datetime import datetime

from aksnetval import _cli

ZONES = ("1", "2", "3")
PE_NET = ipaddress.IPv4Network("10.50.2.0/24")
AKS_NET = ipaddress.IPv4Network("10.50.4.0/22")


def _num(x: float) -> str:
    return str(int(x)) if float(x).is_integer() else str(x)


def _counts(by_zone: dict) -> list[int]:
    return [int(by_zone.get(z, 0)) for z in ZONES]


def http_verdict(code: str, expect: str, control_passed: bool = True) -> str:
    if expect not in ("200", "403", "blocked"):
        raise ValueError(f"expect 값이 올바르지 않습니다: {expect}")
    # 대조군이 실패하면 차단의 원인을 알 수 없으므로 결과와 무관하게 INCONCLUSIVE
    if not control_passed:
        return "INCONCLUSIVE"
    expected = "000" if expect == "blocked" else expect
    return "PASS" if code == expected else "FAIL"


def is_pe_ip(ip: str) -> bool:
    try:
        return ipaddress.IPv4Address(ip) in PE_NET
    except ValueError:
        return False


def tls_verdict(resolved_ip: str, code: str, expect: str, control_passed: bool = True, expected_ip: str = "") -> str:
    if expect not in ("ok", "fail"):
        raise ValueError(f"expect 값이 올바르지 않습니다: {expect}")
    if not control_passed:
        return "INCONCLUSIVE"
    # DNS가 PE IP로 해석되지 않으면 NetworkPolicy 경로를 검증한 것이 아님
    if not is_pe_ip(resolved_ip):
        return "INCONCLUSIVE"
    # /32 허용 정책은 고정 PE IP 기준이므로 다른 IP 로 해석되면 그 정책을 검증한 것이 아님
    if expected_ip and resolved_ip != expected_ip:
        return "INCONCLUSIVE"
    connected = code != "000"
    ok = connected if expect == "ok" else not connected
    return "PASS" if ok else "FAIL"


def node_reach_verdict(code: str, ran: bool, control_code: str, control_ran: bool) -> str:
    # 대조군(정책 없는 Pod)이 노드에 닿아야 비교 대상 Pod 의 000 을 정책 차단으로 볼 수 있다
    if not (control_ran and control_code != "000") or not ran:
        return "INCONCLUSIVE"
    return "PASS" if code != "000" else "FAIL"


def started_after(pod_start: str, policy_created: str) -> bool:
    # Python 3.10(Ubuntu 22.04)의 fromisoformat 은 'Z' 를 받지 않는다
    def parse(s: str) -> datetime:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))

    try:
        return parse(pod_start) > parse(policy_created)
    except (AttributeError, TypeError, ValueError):
        return False


def hpa_verdict(samples: list[dict]) -> dict:
    expected_seq = [5, 4, 3, 2]
    min_interval = 55
    ordered = sorted(samples, key=lambda s: datetime.fromisoformat(s["time"]))
    seq: list[int] = []
    change_times: list[datetime] = []
    # 연속 중복 제거: 값이 바뀐 시각만 남긴다
    for s in ordered:
        rep = int(s["replicas"])
        if not seq:
            seq.append(rep)
        elif rep != seq[-1]:
            seq.append(rep)
            change_times.append(datetime.fromisoformat(s["time"]))
    intervals = [(b - a).total_seconds() for a, b in zip(change_times, change_times[1:])]
    seq_text = ",".join(map(str, seq))
    iv_text = ",".join(_num(i) for i in intervals)

    reason = None
    if not seq:
        reason = "표본이 없습니다"
    elif 2 not in seq:
        reason = f"레플리카가 2에 도달하지 않았습니다 (관측 순서: {seq_text})"
    elif seq != expected_seq:
        reason = f"레플리카 순서가 5,4,3,2가 아닙니다 (관측 순서: {seq_text})"
    elif any(i < min_interval for i in intervals):
        reason = f"감소 간격이 {min_interval}초 미만입니다 (간격: {iv_text}초)"
    verdict = "FAIL" if reason else "PASS"
    if not reason:
        reason = f"5→4→3→2 순서로 감소, 간격 {iv_text}초"
    return {"verdict": verdict, "sequence": seq, "intervals_sec": intervals, "reason": reason}


def zone_balance_verdict(nodes_by_zone: dict, pending: int, nodes_before: int = -1) -> dict:
    c = _counts(nodes_by_zone)
    summary = f"영역1={c[0]}, 영역2={c[1]}, 영역3={c[2]}"
    # 확장 없이 Pending 이 남는 경우(할당량 부족 등)는 FAIL 이므로 Pending 을 먼저 본다
    if pending > 0:
        return {"verdict": "FAIL", "reason": f"Pending Pod가 {pending}개 남아 있습니다 ({summary})"}
    total = sum(c)
    if nodes_before >= 0 and total <= nodes_before:
        return {"verdict": "INCONCLUSIVE", "reason": f"CAS 확장 없음: 사용자 노드 {nodes_before} → {total}대 ({summary})"}
    diff = max(c) - min(c)
    if diff <= 1:
        return {"verdict": "PASS", "reason": f"영역별 노드 수 차이 {diff} ≤ 1 ({summary})"}
    return {"verdict": "FAIL", "reason": f"영역별 노드 수 차이 {diff} > 1 ({summary})"}


def nsg_reuse_verdict(t1_verdict: str, rule_access: str | None, subnet_nsg_id: str | None, nsg_name: str, rule_name: str) -> dict:
    # T3: nsg-ingress 에 Deny 규칙이 있고 snet-ingress 에 연결된 것이 확인될 때만 T1 판정을 재사용한다
    if rule_access != "Deny":
        got = f"access={rule_access}" if rule_access else "없음"
        return {"verdict": "INCONCLUSIVE", "note": f"{nsg_name}/{rule_name} Deny 규칙 확인 실패({got}): T1 재사용 불가"}
    attached = subnet_nsg_id.rstrip("/").split("/")[-1] if subnet_nsg_id else ""
    if attached != nsg_name:
        got = attached or "없음"
        return {"verdict": "INCONCLUSIVE", "note": f"서브넷 NSG 연결이 {nsg_name} 이 아님(연결된 NSG: {got}): T1 재사용 불가"}
    return {"verdict": t1_verdict, "note": f"{nsg_name}/{rule_name} Deny 규칙과 서브넷 연결 확인, T1 결과 재사용"}


def pod_spread_verdict(pods_by_zone: dict, pending: int, expected: int) -> dict:
    c = _counts(pods_by_zone)
    summary = f"Pod 영역1={c[0]}, 영역2={c[1]}, 영역3={c[2]}"
    if pending > 0:
        return {"verdict": "FAIL", "reason": f"Pending Pod가 {pending}개 남아 있습니다 ({summary})"}
    total = sum(c)
    if total != expected:
        return {"verdict": "INCONCLUSIVE", "reason": f"Running Pod {total}/{expected} ({summary})"}
    diff = max(c) - min(c)
    ok = diff <= 1
    return {"verdict": "PASS" if ok else "FAIL", "reason": f"영역별 Pod 수 차이 {diff} {'≤' if ok else '>'} 1 ({summary})"}


def zone_floor_verdict(rounds: list[dict], expected: int) -> dict:
    # T12c: minReplicas 3 으로 축소한 각 회차에서 세 영역 모두 Pod 가 1개 이상 남았는지
    if not rounds:
        return {"verdict": "INCONCLUSIVE", "reason": "측정한 회차 없음"}
    counts = [_counts(r) for r in rounds]
    all_text = ", ".join(f"{i + 1}회 {'/'.join(map(str, c))}" for i, c in enumerate(counts))
    for i, c in enumerate(counts):
        if sum(c) != expected:
            return {"verdict": "INCONCLUSIVE", "reason": f"{i + 1}회 Running Pod 수가 {expected} 이 아님 ({all_text})"}
    for i, c in enumerate(counts):
        if min(c) < 1:
            return {"verdict": "FAIL", "reason": f"{i + 1}회에 Pod가 없는 영역 발생 ({all_text})"}
    return {"verdict": "PASS", "reason": f"{len(rounds)}회 모두 세 영역에 1개 이상 ({all_text})"}


def probe_rewrite_verdict(pods: list[dict]) -> dict:
    # T14: 각 Pod 의 app 컨테이너 readinessProbe 가 Istio 에 의해 15020 /app-health/ 로 바뀌었고 Ready 인지
    n = len(pods)
    if n == 0:
        return {"verdict": "INCONCLUSIVE", "observed": "Pod 없음", "reason": "대상 Pod 없음"}

    def rewritten(p):
        return str(p.get("port")) == "15020" and str(p.get("path") or "").startswith("/app-health/")

    no_probe = [p for p in pods if not p.get("path")]
    not_rw = [p for p in pods if p.get("path") and not rewritten(p)]
    not_ready = [p for p in pods if not p.get("ready")]
    rw = sum(1 for p in pods if rewritten(p))
    observed = f"Ready {n - len(not_ready)}/{n}, rewrite {rw}/{n}"
    names = lambda lst: ", ".join(p["name"] for p in lst)  # noqa: E731
    if no_probe:
        reason = f"readinessProbe 없음: {names(no_probe)}"
    elif not_rw:
        reason = "probe rewrite 안 됨: " + ", ".join(f"{p['name']}={p.get('port')}{p.get('path')}" for p in not_rw)
    elif not_ready:
        reason = f"Not Ready: {names(not_ready)}"
    else:
        return {"verdict": "PASS", "observed": observed, "reason": f"모든 Pod가 15020 {pods[0]['path']} 로 rewrite 후 Ready"}
    return {"verdict": "FAIL", "observed": observed, "reason": reason}


def _in_net(ip: str, net: ipaddress.IPv4Network) -> bool:
    try:
        return ipaddress.IPv4Address(ip) in net
    except ValueError:
        return False


def _is_public(ip: str) -> bool:
    try:
        return ipaddress.IPv4Address(ip).is_global
    except ValueError:
        return False


def api_private_verdict(private_enabled: bool, public_fqdn_enabled: bool, vm_ips: list[str], readyz_ok: bool, local_ip: str, local_connected: bool) -> dict:
    # T15: FAIL(구성 위반) > INCONCLUSIVE(관측 불충분) > PASS 순으로 판정한다
    observed = (
        f"private={private_enabled}, publicFqdn={public_fqdn_enabled}, vm={','.join(vm_ips) or '없음'}, "
        f"readyz={'ok' if readyz_ok else 'fail'}, local={local_ip or 'NXDOMAIN'}/{'연결' if local_connected else '실패'}"
    )
    fails = []
    if not private_enabled:
        fails.append("Private Cluster가 아닙니다")
    if public_fqdn_enabled:
        fails.append("public FQDN이 켜져 있습니다")
    if not vm_ips or not all(_in_net(ip, AKS_NET) for ip in vm_ips):
        fails.append(f"vm-mgmt 해석 IP가 {AKS_NET} 밖입니다")
    if _is_public(local_ip):
        fails.append(f"로컬에서 공인 IP({local_ip})로 해석됩니다")
    if fails:
        return {"verdict": "FAIL", "observed": observed, "reason": "; ".join(fails)}
    if not readyz_ok:
        return {"verdict": "INCONCLUSIVE", "observed": observed, "reason": "vm-mgmt 에서 /readyz 확인 실패"}
    if local_connected:
        return {"verdict": "INCONCLUSIVE", "observed": observed, "reason": "로컬에서 API 서버 443 연결이 성공했습니다(VPN 등 사설 경로 확인 필요)"}
    return {"verdict": "PASS", "observed": observed, "reason": "API 서버는 사설 IP로만 해석·접근되고 로컬에서는 접근 불가"}


def require(value: str | None, name: str) -> None:
    if value is None or not str(value).strip():
        raise ValueError(f"{name} 값이 비어 있습니다")


def main(argv: list[str]) -> int:
    return _cli.run(globals(), argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
