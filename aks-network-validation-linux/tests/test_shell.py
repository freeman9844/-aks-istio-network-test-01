"""bash 스크립트 문법과 config.sh·common.sh 동작 검사."""
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = sorted(p for p in ROOT.rglob("*.sh") if ".bundle" not in p.parts)


def bash(script: str, env: dict | None = None, cwd: Path = ROOT) -> subprocess.CompletedProcess:
    base = {"PATH": "/usr/bin:/bin", "HOME": "/tmp"}
    return subprocess.run(["bash", "-c", script], capture_output=True, text=True, cwd=cwd, env={**base, **(env or {})})


@pytest.fixture
def az_stub(tmp_path):
    stub = tmp_path / "az"
    stub.write_text("#!/usr/bin/env bash\necho 00000000-0000-0000-0000-000000000000\n", encoding="utf-8")
    stub.chmod(0o755)
    return str(stub)


def test_scripts_exist():
    assert SCRIPTS, "검사할 .sh 가 없습니다"


@pytest.mark.parametrize("path", SCRIPTS, ids=lambda p: str(p.relative_to(ROOT)))
def test_bash_syntax(path):
    r = subprocess.run(["bash", "-n", str(path)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


@pytest.mark.skipif(shutil.which("shellcheck") is None, reason="shellcheck 없음")
def test_shellcheck():
    r = subprocess.run(["shellcheck", "-x", "-S", "warning", *map(str, SCRIPTS)], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout


def test_role_assignment_list_avoids_graph_lookup():
    # --assignee 는 Graph(graph.microsoft.com) 조회를 일으켜, Graph 에 닿지 않는 환경에서 실패한다
    bad = [str(p.relative_to(ROOT)) for p in SCRIPTS
           if any("role assignment list" in ln and "--assignee" in ln for ln in p.read_text(encoding="utf-8").splitlines())]
    assert bad == []


def test_checked_commands_not_in_process_substitution():
    # < <(kube_ok …) 안의 die 는 프로세스 치환만 끝내고 set -e 에 걸리지 않아 실패가 묻힌다
    bad = [f"{p.relative_to(ROOT)}:{n}" for p in SCRIPTS
           for n, ln in enumerate(p.read_text(encoding="utf-8").splitlines(), 1)
           if re.search(r"<\(\s*(kube_ok|az_ok)\b", ln)]
    assert bad == []


def test_apply_restarts_app_after_policy_second_boundary():
    # creationTimestamp·startTime 은 초 단위라 같은 초에 재시작하면 T20 이 '정책 이후 기동'을 증명하지 못한다
    lines = (ROOT / "vm" / "02-apply.sh").read_text(encoding="utf-8").splitlines()
    i = next(n for n, ln in enumerate(lines) if "31-app-pe-egress.yaml" in ln and ln.startswith("apply_manifest"))
    j = next(n for n, ln in enumerate(lines) if "rollout restart deployment -n app" in ln)
    assert any(ln.strip().startswith("sleep") for ln in lines[i + 1:j])


def test_config_values(az_stub):
    r = bash('source config.sh && echo "$RG $SNET_MGMT_PREFIX ${#USER_POOLS[@]} $STORAGE"', {"AZ": az_stub})
    assert r.returncode == 0, r.stderr
    rg, mgmt, pools, storage = r.stdout.split()
    assert (rg, mgmt, pools) == ("rg-aksnetval-linux-krc", "10.50.3.64/27", "3")
    assert storage.startswith("staksnetval") and len(storage) == len("staksnetval") + 6


def test_config_second_blob_pe(az_stub):
    r = bash('source config.sh && echo "$STORAGE $STORAGE2 $BLOB_PE_IP $BLOB2_PE $BLOB2_PE_IP"', {"AZ": az_stub})
    assert r.returncode == 0, r.stderr
    storage, storage2, ip1, pe2, ip2 = r.stdout.split()
    assert storage2.startswith("staksnetvalb") and storage2[-6:] == storage[-6:]
    assert (ip1, pe2, ip2) == ("10.50.2.4", "pe-blob2-aksnetval", "10.50.2.5")


def test_config_rg_override(az_stub):
    r = bash('source config.sh && echo "$RG"', {"AZ": az_stub, "AKSNETVAL_RG": "x"})
    assert r.stdout.strip() == "x"


def test_config_fails_without_login(tmp_path):
    stub = tmp_path / "az"
    stub.write_text("#!/usr/bin/env bash\nexit 1\n", encoding="utf-8")
    stub.chmod(0o755)
    r = bash("set -euo pipefail; source config.sh; echo after", {"AZ": str(stub)})
    assert r.returncode != 0
    assert "after" not in r.stdout


@pytest.mark.parametrize("value,rc", [("", 0), ("true", 0), ("false", 1), ("null", 1)])
def test_aks_private_guard(value, rc):
    r = bash(f'source vm/lib/common.sh && aks_private_guard "{value}"')
    assert r.returncode == rc, r.stderr


def test_retry_succeeds_after_failures(tmp_path):
    marker = tmp_path / "n"
    r = bash(f'source vm/lib/common.sh && retry 3 0 bash -c \'echo x >> {marker}; [ $(wc -l < {marker}) -ge 2 ]\'')
    assert r.returncode == 0, r.stderr
    assert marker.read_text().count("x") == 2


def test_az_ok_reports_failed_command(tmp_path):
    stub = tmp_path / "az"
    stub.write_text("#!/usr/bin/env bash\necho boom >&2; exit 3\n", encoding="utf-8")
    stub.chmod(0o755)
    r = bash("source vm/lib/common.sh && az_ok group show -n x", {"AZ": str(stub)})
    assert r.returncode != 0
    assert "group show" in r.stderr and "boom" in r.stderr


@pytest.mark.parametrize("out,rc,expected", [
    ('{"name": "default"}', 0, 0),
    ("{}", 0, 1),     # dns-zone-group show 는 없는 리소스에 {} 와 rc 0 을 돌려준다
    ("", 0, 1),
    ("null", 0, 1),
    ('{"name": "x"}', 3, 1),
])
def test_exists_treats_empty_object_as_missing(tmp_path, out, rc, expected):
    stub = tmp_path / "az"
    stub.write_text(f"#!/usr/bin/env bash\necho '{out}'; exit {rc}\n", encoding="utf-8")
    stub.chmod(0o755)
    r = bash("source vm/lib/common.sh && exists network x show", {"AZ": str(stub)})
    assert (r.returncode == 0) == (expected == 0)
