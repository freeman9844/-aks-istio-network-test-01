"""curl·DNS 출력 파서와 vCPU 필요량 계산(기존 Common.psm1 대응)."""
import ipaddress
import re
import sys
from dataclasses import dataclass

from aksnetval import _cli

_STDOUT = re.compile(r"(?s)\[stdout\](.*?)(\[stderr\]|$)")
_CODE = re.compile(r"(?m)^\s*(\d{3})\s*$")
_RC = re.compile(r"(?m)^\s*rc=(\d+)\s*$")
_ZONE = re.compile(r"^(?:.*-)?(\d+)$")

SIZE_CORES = {"Standard_D4s_v5": 4, "Standard_D2s_v5": 2, "Standard_B2s_v2": 2}
SYSTEM_VM_SIZE = "Standard_D4s_v5"
USER_VM_SIZE = "Standard_D2s_v5"
USER_POOL_COUNT = 3
USER_MAX = 3
VM_SIZE = "Standard_B2s_v2"
VM_COUNT = 3  # vm-appgw-sim, vm-other, vm-mgmt


def _stdout_part(text: str) -> str:
    m = _STDOUT.search(text)
    return m.group(1) if m else text


def curl_code(output: str | None) -> str:
    if output is None or not output.strip():
        return "000"
    codes = _CODE.findall(_stdout_part(output))
    return codes[-1] if codes else "000"


def first_ipv4(output: str | None) -> str:
    if output is None or not output.strip():
        return ""
    for line in output.splitlines():
        parts = line.split()
        if not parts:
            continue
        try:
            ipaddress.IPv4Address(parts[0])
            return parts[0]
        except ValueError:
            continue
    return ""


@dataclass
class CurlRun:
    ran: bool
    code: str
    rc: int | None


def curl_run(output: str | None) -> CurlRun:
    text = _stdout_part(output or "")
    m = _RC.search(text)
    if not m:
        return CurlRun(False, "000", None)
    rc = int(m.group(1))
    # 126(실행 불가)·127(명령 없음)은 curl 자체가 돌지 않은 것
    if rc in (126, 127):
        return CurlRun(False, "000", rc)
    return CurlRun(True, curl_code(text), rc)


def zone_key(zone: str | None) -> str:
    m = _ZONE.match(zone or "")
    return m.group(1) if m else ""


def zone_counts(zones: list[str]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for z in zones:
        k = zone_key(z)
        if k:
            counts[k] = counts.get(k, 0) + 1
    return counts


def vcpu_need(own_dsv5: int = 0, own_vm_count: int = 0) -> dict:
    max_dsv5 = SIZE_CORES[SYSTEM_VM_SIZE] + USER_POOL_COUNT * USER_MAX * SIZE_CORES[USER_VM_SIZE]
    vm_cores = SIZE_CORES[VM_SIZE]
    max_bsv2 = VM_COUNT * vm_cores
    own_bsv2 = own_vm_count * vm_cores
    return {
        "max_dsv5": max_dsv5,
        "max_bsv2": max_bsv2,
        "max_total": max_dsv5 + max_bsv2,
        "dsv5": max(0, max_dsv5 - own_dsv5),
        "bsv2": max(0, max_bsv2 - own_bsv2),
        "total": max(0, max_dsv5 + max_bsv2 - own_dsv5 - own_bsv2),
    }


def main(argv: list[str]) -> int:
    return _cli.run(globals(), argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
