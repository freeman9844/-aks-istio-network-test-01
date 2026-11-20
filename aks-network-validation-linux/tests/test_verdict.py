import json
from datetime import datetime, timedelta

import pytest

from aksnetval.verdict import (
    api_private_verdict,
    hpa_verdict,
    http_verdict,
    is_pe_ip,
    main,
    nsg_reuse_verdict,
    pod_spread_verdict,
    probe_rewrite_verdict,
    require,
    started_after,
    tls_verdict,
    zone_balance_verdict,
    zone_floor_verdict,
)


# T1~T11 HTTP
def test_http_200_pass():
    assert http_verdict("200", "200") == "PASS"


def test_http_403_got_200_fail():
    assert http_verdict("200", "403") == "FAIL"


def test_http_blocked_000_pass():
    assert http_verdict("000", "blocked") == "PASS"


def test_http_control_failed_inconclusive():
    assert http_verdict("000", "blocked", control_passed=False) == "INCONCLUSIVE"


def test_http_bad_expect_raises():
    with pytest.raises(ValueError):
        http_verdict("200", "ok")


# TLS
def test_tls_pe_000_fail_expected_pass():
    assert tls_verdict("10.50.2.4", "000", "fail") == "PASS"


def test_tls_pe_400_ok_expected_pass():
    assert tls_verdict("10.50.2.4", "400", "ok") == "PASS"


def test_tls_public_ip_inconclusive():
    assert tls_verdict("20.1.2.3", "000", "fail") == "INCONCLUSIVE"


def test_is_pe_ip_other_subnet():
    assert is_pe_ip("10.50.20.4") is False


# T11·T16~T18: NetworkPolicy 가 /32 로 허용하므로 해석 IP 가 고정 PE IP 와 달라도 경로 검증이 아님
def test_tls_expected_ip_mismatch_inconclusive():
    assert tls_verdict("10.50.2.6", "400", "ok", expected_ip="10.50.2.5") == "INCONCLUSIVE"


def test_tls_expected_ip_match_pass():
    assert tls_verdict("10.50.2.5", "000", "fail", expected_ip="10.50.2.5") == "PASS"


# T20: 정책 적용 뒤에 기동한 Pod 여야 istiod 연결이 정책 아래에서 이루어졌다고 볼 수 있다
@pytest.mark.parametrize("pod,policy,expected", [
    ("2026-01-01T00:10:00Z", "2026-01-01T00:00:00Z", True),
    ("2026-01-01T00:00:00Z", "2026-01-01T00:10:00Z", False),
    ("", "2026-01-01T00:00:00Z", False),
    ("2026-01-01T00:10:00Z", "bad", False),
])
def test_started_after(pod, policy, expected):
    assert started_after(pod, policy) is expected


# T12 HPA
def _samples(pairs):
    t0 = datetime(2026, 1, 1)
    return [{"time": (t0 + timedelta(seconds=s)).isoformat(), "replicas": r} for s, r in pairs]


def test_hpa_pass():
    r = hpa_verdict(_samples([(0, 5), (10, 5), (60, 4), (90, 4), (120, 3), (180, 2)]))
    assert r["verdict"] == "PASS"
    assert r["sequence"] == [5, 4, 3, 2]


def test_hpa_short_interval_fail():
    assert hpa_verdict(_samples([(0, 5), (60, 4), (90, 3), (150, 2)]))["verdict"] == "FAIL"


def test_hpa_skip_fail():
    assert hpa_verdict(_samples([(0, 5), (60, 3), (120, 2)]))["verdict"] == "FAIL"


def test_hpa_not_reached_2_fail():
    r = hpa_verdict(_samples([(0, 5), (60, 4)]))
    assert r["verdict"] == "FAIL"
    assert "2" in r["reason"]


# T13 영역 균형
def test_zone_balance_222_pass():
    assert zone_balance_verdict({"1": 2, "2": 2, "3": 2}, 0)["verdict"] == "PASS"


def test_zone_balance_321_fail():
    assert zone_balance_verdict({"1": 3, "2": 2, "3": 1}, 0)["verdict"] == "FAIL"


def test_zone_balance_missing_zone_fail():
    assert zone_balance_verdict({"1": 3, "2": 3}, 0)["verdict"] == "FAIL"


def test_zone_balance_pending_fail():
    r = zone_balance_verdict({"1": 2, "2": 2, "3": 2}, 1)
    assert r["verdict"] == "FAIL"
    assert "Pending" in r["reason"]


def test_zone_balance_no_scaleout_inconclusive():
    r = zone_balance_verdict({"1": 1, "2": 1, "3": 1}, 0, nodes_before=3)
    assert r["verdict"] == "INCONCLUSIVE"
    assert "CAS 확장 없음" in r["reason"]


def test_zone_balance_no_scaleout_pending_fail():
    r = zone_balance_verdict({"1": 1, "2": 1, "3": 1}, 2, nodes_before=3)
    assert r["verdict"] == "FAIL"
    assert "Pending" in r["reason"]


def test_zone_balance_scaled_out_pass():
    assert zone_balance_verdict({"1": 2, "2": 2, "3": 2}, 0, nodes_before=3)["verdict"] == "PASS"


def test_require_empty_raises():
    with pytest.raises(ValueError, match="GatewaySA"):
        require("", "GatewaySA")


# T3 NSG 재사용
NSG_ID = "/subscriptions/x/resourceGroups/rg/providers/Microsoft.Network/networkSecurityGroups/nsg-ingress"


def _nsg(t1="PASS", access="Deny", nsg_id=NSG_ID):
    return nsg_reuse_verdict(t1, access, nsg_id, "nsg-ingress", "deny-appgw-all")


def test_nsg_reuse_pass():
    r = _nsg()
    assert r["verdict"] == "PASS"
    assert "deny-appgw-all" in r["note"]


def test_nsg_reuse_t1_fail():
    assert _nsg(t1="FAIL")["verdict"] == "FAIL"


def test_nsg_no_rule_inconclusive():
    r = _nsg(access="")
    assert r["verdict"] == "INCONCLUSIVE"
    assert "deny-appgw-all" in r["note"]


def test_nsg_allow_inconclusive():
    assert _nsg(access="Allow")["verdict"] == "INCONCLUSIVE"


def test_nsg_other_attached_inconclusive():
    r = _nsg(nsg_id=NSG_ID + "-old")
    assert r["verdict"] == "INCONCLUSIVE"
    assert "서브넷" in r["note"]


def test_nsg_not_attached_inconclusive():
    assert _nsg(nsg_id="")["verdict"] == "INCONCLUSIVE"


# T13b Pod 분산
def test_spread_222_pass():
    assert pod_spread_verdict({"1": 2, "2": 2, "3": 2}, 0, 6)["verdict"] == "PASS"


def test_spread_321_fail():
    assert pod_spread_verdict({"1": 3, "2": 2, "3": 1}, 0, 6)["verdict"] == "FAIL"


def test_spread_pending_fail():
    r = pod_spread_verdict({"1": 1, "2": 1, "3": 1}, 3, 6)
    assert r["verdict"] == "FAIL"
    assert "Pending" in r["reason"]


def test_spread_short_inconclusive():
    assert pod_spread_verdict({"1": 2, "2": 2}, 0, 6)["verdict"] == "INCONCLUSIVE"


# T14 probe rewrite
def _p(name, ready, port, path):
    return {"name": name, "ready": ready, "port": port, "path": path}


def test_probe_pass():
    r = probe_rewrite_verdict([_p("web/a", True, 15020, "/app-health/app/readyz"), _p("app/b", True, 15020, "/app-health/app/readyz")])
    assert r["verdict"] == "PASS"
    assert r["observed"] == "Ready 2/2, rewrite 2/2"


def test_probe_not_rewritten_fail():
    assert probe_rewrite_verdict([_p("web/a", True, 8080, "/")])["verdict"] == "FAIL"


def test_probe_missing_fail():
    assert probe_rewrite_verdict([_p("web/a", True, None, None)])["verdict"] == "FAIL"


def test_probe_not_ready_fail():
    assert probe_rewrite_verdict([_p("web/a", False, 15020, "/app-health/app/readyz")])["verdict"] == "FAIL"


def test_probe_no_pods_inconclusive():
    assert probe_rewrite_verdict([])["verdict"] == "INCONCLUSIVE"


# T12c 영역 하한
def test_floor_pass():
    rounds = [{"1": 1, "2": 1, "3": 1}] * 3
    assert zone_floor_verdict(rounds, 3)["verdict"] == "PASS"


def test_floor_empty_zone_fail():
    r = zone_floor_verdict([{"1": 1, "2": 1, "3": 1}, {"1": 2, "3": 1}], 3)
    assert r["verdict"] == "FAIL"
    assert "2회" in r["reason"]


def test_floor_count_mismatch_inconclusive():
    assert zone_floor_verdict([{"1": 1, "2": 1}], 3)["verdict"] == "INCONCLUSIVE"


def test_floor_no_rounds_inconclusive():
    assert zone_floor_verdict([], 3)["verdict"] == "INCONCLUSIVE"


def test_cli_string_result(capsys):
    assert main(["http_verdict", '{"code":"000","expect":"blocked"}']) == 0
    assert json.loads(capsys.readouterr().out) == {"verdict": "PASS"}


_BASE = dict(private_enabled=True, public_fqdn_enabled=False, vm_ips=["10.50.4.5"], readyz_ok=True, local_ip="", local_connected=False)


@pytest.mark.parametrize("over,expected", [
    ({}, "PASS"),
    (dict(private_enabled=False), "FAIL"),
    (dict(public_fqdn_enabled=True), "FAIL"),
    (dict(vm_ips=["10.50.1.5"]), "FAIL"),
    (dict(vm_ips=[]), "FAIL"),
    (dict(local_ip="20.1.2.3"), "FAIL"),
    (dict(readyz_ok=False), "INCONCLUSIVE"),
    (dict(local_ip="10.50.4.5", local_connected=True), "INCONCLUSIVE"),
    (dict(private_enabled=False, readyz_ok=False, local_connected=True), "FAIL"),
])
def test_api_private_verdict(over, expected):
    r = api_private_verdict(**{**_BASE, **over})
    assert r["verdict"] == expected
    assert r["reason"]


def test_api_private_verdict_observed_format():
    r = api_private_verdict(**_BASE)
    assert r["observed"] == "private=True, publicFqdn=False, vm=10.50.4.5, readyz=ok, local=NXDOMAIN/실패"