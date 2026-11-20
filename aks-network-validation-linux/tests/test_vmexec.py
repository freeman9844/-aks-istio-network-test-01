"""local/lib/vmexec.sh 전송 계층 검사. AKSNETVAL_FAKE_VM=1 로 run-command 를 로컬 bash 로 흉내낸다."""
import hashlib
import io
import os
import subprocess
import tarfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "local" / "lib" / "vmexec.sh"


def run(script: str, vm_root: Path, **env) -> subprocess.CompletedProcess:
    full = {"PATH": "/usr/bin:/bin", "HOME": "/tmp", "AKSNETVAL_FAKE_VM": "1", "VM_ROOT": str(vm_root), "POLL": "0", **env}
    return subprocess.run(["bash", "-c", f"set -euo pipefail; source '{LIB}'; {script}"], capture_output=True, text=True, env=full)


@pytest.fixture
def vm(tmp_path):
    d = tmp_path / "vm"
    d.mkdir()
    return d


def test_stdout_section_extracts_between_markers(vm):
    r = run("stdout_section $'Enable succeeded: \\n[stdout]\\nhello\\nworld\\n\\n[stderr]\\nwarn'", vm)
    assert r.stdout.strip() == "hello\nworld"


def test_stdout_section_missing(vm):
    r = run("stdout_section 'Enable failed: no output'", vm)
    assert r.returncode == 0
    assert r.stdout == ""


def test_vm_exec_returns_remote_rc(vm):
    r = run("vm_exec 'echo hi; exit 3'", vm)
    assert r.returncode == 3
    assert r.stdout.strip() == "hi"


def _tgz(path: Path, files: dict) -> Path:
    with tarfile.open(path, "w:gz") as tf:
        for name, data in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))
    return path


@pytest.mark.parametrize("prefix", ["", "./"])  # build_bundle 은 tar -C dir . 로 만들어 항목이 ./ 로 시작한다
@pytest.mark.parametrize("chunk", ["32000", "100"])
def test_upload_roundtrip(vm, tmp_path, chunk, prefix):
    files = {"config.sh": b"echo cfg\n", "aksnetval/x.py": os.urandom(500), "vm/01-infra.sh": "한글\n".encode()}
    tgz = _tgz(tmp_path / "b.tgz", {prefix + k: v for k, v in files.items()})
    (vm / "state").mkdir()
    (vm / "state" / "keep").write_text("k")
    (vm / "aksnetval").mkdir()
    (vm / "aksnetval" / "old.py").write_text("old")
    r = run(f"upload_bundle '{tgz}'", vm, UPLOAD_CHUNK=chunk)
    assert r.returncode == 0, r.stderr
    for name, data in files.items():
        assert (vm / name).read_bytes() == data
    assert (vm / "state" / "keep").read_text() == "k"
    assert not (vm / "aksnetval" / "old.py").exists()


@pytest.mark.parametrize("size", [0, 2250, 7001])
def test_fetch_roundtrip_sizes(vm, tmp_path, size):
    data = os.urandom(size)
    (vm / "r.bin").write_bytes(data)
    out = tmp_path / "out.bin"
    r = run(f"fetch_file '{vm / 'r.bin'}' '{out}'", vm)
    assert r.returncode == 0, r.stderr
    assert hashlib.sha256(out.read_bytes()).hexdigest() == hashlib.sha256(data).hexdigest()


def test_fetch_detects_corruption(vm, tmp_path):
    (vm / "r.bin").write_bytes(b"abc")
    script = (
        'eval "orig_$(declare -f vm_exec)"; '
        'vm_exec() { local o; o="$(orig_vm_exec "$1")" || return; '
        'if [[ "$1" == *sha256sum* ]]; then echo "deadbeef ${o#* }"; else printf "%s\\n" "$o"; fi; }; '
        f"fetch_file '{vm / 'r.bin'}' '{tmp_path / 'o'}'"
    )
    r = run(script, vm)
    assert r.returncode != 0


@pytest.mark.parametrize("state,action", [("active", "follow"), ("activating", "follow"), ("inactive", "start"), ("failed", "start"), ("", "start")])
def test_stage_action(vm, state, action):
    assert run(f"stage_action '{state}'", vm).stdout.strip() == action


def _finished_stage(vm: Path, rc: int, lines: int = 3):
    (vm / "logs").mkdir()
    (vm / "state").mkdir()
    (vm / "logs" / "verify.log").write_text("".join(f"줄{i}\n" for i in range(lines)), encoding="utf-8")
    (vm / "state" / "verify.rc").write_text(f"{rc}\n")


def _flaky(fail_times: int, counter: Path) -> str:
    return (
        'eval "orig_$(declare -f vm_exec)"; '
        f'vm_exec() {{ local n; n=$(( $(cat {counter} 2>/dev/null || echo 0) + 1 )); echo $n > {counter}; '
        f'(( n <= {fail_times} )) && return 1; orig_vm_exec "$1"; }}; '
    )


def test_poll_reads_all_lines_and_returns_rc(vm):
    _finished_stage(vm, 0, lines=400)
    r = run("poll_stage verify", vm)
    assert r.returncode == 0, r.stderr
    out = r.stdout.splitlines()
    assert [l for l in out if l.startswith("줄")] == [f"줄{i}" for i in range(400)]


def test_poll_propagates_stage_failure(vm):
    _finished_stage(vm, 4)
    assert run("poll_stage verify", vm).returncode == 4


def test_poll_tolerates_transient(vm, tmp_path):
    _finished_stage(vm, 0)
    r = run(_flaky(2, tmp_path / "c") + "poll_stage verify", vm)
    assert r.returncode == 0, r.stderr


def test_poll_gives_up_after_three_failures(vm, tmp_path):
    _finished_stage(vm, 0)
    r = run(_flaky(3, tmp_path / "c") + "poll_stage verify", vm)
    assert r.returncode != 0


@pytest.mark.parametrize("args", [[], ["bogus"], ["verify", "--only", "x"], ["verify", "--poll", "abc"]])
def test_run_sh_rejects_bad_args(tmp_path, args):
    stub = tmp_path / "az"
    stub.write_text("#!/usr/bin/env bash\necho 00000000-0000-0000-0000-000000000000\n", encoding="utf-8")
    stub.chmod(0o755)
    r = subprocess.run(["bash", str(ROOT / "local" / "run.sh"), *args], capture_output=True, text=True,
                       env={"PATH": "/usr/bin:/bin", "HOME": "/tmp", "AZ": str(stub)})
    assert r.returncode == 2
    assert "사용법" in r.stderr