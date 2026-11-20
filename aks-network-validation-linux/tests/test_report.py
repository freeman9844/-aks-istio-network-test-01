import json
import socket
from pathlib import Path

from aksnetval import localprobe, report


def _rows():
    return [
        report.row("T2", "web-a", "data", "200", "200", "PASS"),
        report.row("T1", "client", "web", "blocked", "a|b\nc", "PASS", "메모"),
    ]


def test_row_keys_are_column_names():
    assert list(report.row("T1", "a", "b", "200", "200", "PASS").keys()) == list(report.COLUMNS)


def test_save_escapes_pipe_and_newline(tmp_path):
    out = report.save(_rows(), str(tmp_path), stamp="20261120-000000")
    md = Path(out["md"]).read_text(encoding="utf-8")
    assert "a\\|b c" in md
    assert md.splitlines()[0] == "# 검증 결과 20261120-000000"


def test_save_columns_order(tmp_path):
    out = report.save(_rows(), str(tmp_path), stamp="s")
    md = Path(out["md"]).read_text(encoding="utf-8").splitlines()
    assert md[2] == "| Id | From | To | Expect | Observed | Verdict | Note |"
    data = json.loads(Path(out["json"]).read_text(encoding="utf-8"))
    assert [r["Id"] for r in data] == ["T1", "T2"]  # 정해진 순서로 정렬
    assert list(data[0].keys()) == list(report.COLUMNS)


def test_save_default_stamp_format(tmp_path):
    out = report.save(_rows(), str(tmp_path))
    name = Path(out["json"]).stem
    assert len(name) == 15 and name[8] == "-"


def test_order_places_app_pe_tests_after_t11():
    rows = [report.row(i, "", "", "", "", "PASS") for i in ("T12", "T23", "T21", "T16", "T22", "T11", "T19")]
    data = json.loads(Path(report.save(rows, "/tmp/aksnetval-order", stamp="o")["json"]).read_text(encoding="utf-8"))
    assert [r["Id"] for r in data] == ["T11", "T16", "T19", "T21", "T22", "T23", "T12"]


def test_merge_t15_replaces_existing_row(tmp_path):
    out = report.save(_rows(), str(tmp_path), stamp="s")
    obs = tmp_path / "t15.json"
    obs.write_text(json.dumps(dict(private_enabled=True, public_fqdn_enabled=False, vm_ips=["10.50.4.5"], readyz_ok=True, fqdn="x.privatelink.koreacentral.azmk8s.io")), encoding="utf-8")
    local = {"ip": "", "connected": False}
    report.merge_t15(out["json"], str(obs), local)
    report.merge_t15(out["json"], str(obs), local)
    data = json.loads(Path(out["json"]).read_text(encoding="utf-8"))
    t15 = [r for r in data if r["Id"] == "T15"]
    assert len(t15) == 1
    assert t15[0]["Verdict"] == "PASS"
    assert t15[0]["To"] == "API 서버 x.privatelink.koreacentral.azmk8s.io:443"
    assert "T15" in Path(out["md"]).read_text(encoding="utf-8")


def test_merge_t15_vm_observation_error_is_inconclusive(tmp_path):
    # vm-mgmt 에서 az aks show 가 실패하면 관측값이 비어 있으므로 FAIL("Private 아님")이 아니라 판정 불가여야 한다
    out = report.save(_rows(), str(tmp_path), stamp="s")
    obs = tmp_path / "t15.json"
    obs.write_text(json.dumps(dict(error="az aks show 실패", fqdn="")), encoding="utf-8")
    t15 = report.merge_t15(out["json"], str(obs), {"ip": "", "connected": False})
    assert t15["Verdict"] == "INCONCLUSIVE"
    assert t15["Observed"] == "관측 실패"
    assert t15["Note"] == "vm-mgmt 관측 실패: az aks show 실패"


def test_local_probe_nxdomain():
    r = localprobe.probe("aksnetval-none.invalid", timeout=2)
    assert r == {"ip": "", "connected": False}


def test_local_probe_closed_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    r = localprobe.probe("127.0.0.1", port, timeout=2)
    assert r == {"ip": "127.0.0.1", "connected": False}
