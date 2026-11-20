"""사전 점검(기존 Common.psm1 Test-Preflight 대응). az vm list-usage·list-skus JSON 을 그대로 받는다."""
import json
import sys

from aksnetval.parse import vcpu_need

ZONES = ("1", "2", "3")


def _info(msg: str) -> None:
    print(msg, file=sys.stderr)


def _usage_entry(usage: list, name: str) -> dict | None:
    return next((u for u in usage if ((u.get("name") or {}).get("value") or "").lower() == name.lower()), None)


def _free(u: dict) -> int:
    return int(u["limit"]) - int(u["currentValue"])


def problems(usage: list, skus: list, own_dsv5: int, own_vm_count: int, system_size: str, user_size: str, vm_size: str) -> list[str]:
    out: list[str] = []
    vn = vcpu_need(own_dsv5, own_vm_count)

    dsv5 = _usage_entry(usage, "standardDSv5Family")
    if not dsv5:
        out.append("Standard DSv5 Family 할당량 정보를 찾을 수 없음")
    else:
        free = _free(dsv5)
        _info(f"할당량 Standard DSv5 Family: 사용 {dsv5['currentValue']} / 한도 {dsv5['limit']}, 잔여 {free} vCPU (필요 {vn['dsv5']}, 최대 {vn['max_dsv5']} 중 이 클러스터 사용분 {own_dsv5} 제외)")
        if free < vn["dsv5"]:
            out.append(f"Standard DSv5 Family 잔여 vCPU {free} < 필요 {vn['dsv5']}")

    bsv2 = _usage_entry(usage, "standardBSv2Family")
    if not bsv2:
        out.append("Standard BSv2 Family 할당량 정보를 찾을 수 없음")
    else:
        free = _free(bsv2)
        _info(f"할당량 Standard BSv2 Family: 잔여 {free} vCPU (필요 {vn['bsv2']}, 최대 {vn['max_bsv2']} 중 기존 VM {own_vm_count}대 제외)")
        if free < vn["bsv2"]:
            out.append(f"Standard BSv2 Family 잔여 vCPU {free} < 필요 {vn['bsv2']}")

    total = _usage_entry(usage, "cores")
    if total:
        tfree = _free(total)
        _info(f"할당량 Total Regional vCPUs: 잔여 {tfree} (필요 {vn['total']}, 최대 {vn['max_total']})")
        if tfree < vn["total"]:
            out.append(f"Total Regional vCPUs 잔여 {tfree} < 필요 {vn['total']}")

    by_name = {s.get("name"): s for s in skus}
    for size in dict.fromkeys([system_size, user_size]):
        sku = by_name.get(size)
        if not sku:
            out.append(f"{size} 가 리전에 없음")
            continue
        zones = {z for li in sku.get("locationInfo") or [] for z in li.get("zones") or []}
        restricted: set[str] = set()
        for r in sku.get("restrictions") or []:
            if r.get("type") == "Location":
                restricted.update(ZONES)
            elif r.get("type") == "Zone":
                restricted.update((r.get("restrictionInfo") or {}).get("zones") or [])
        bad = [z for z in ZONES if z not in zones or z in restricted]
        if bad:
            out.append(f"{size} 영역 {','.join(bad)} 사용 불가(제한 또는 미제공)")
        else:
            _info(f"SKU {size}: 영역 1·2·3 제한 없음")

    # 테스트 VM(영역 지정 없음): 리전에 제공되고 리전 제한이 없어야 한다
    vm = by_name.get(vm_size)
    if not vm:
        out.append(f"{vm_size} 가 리전에 없음")
    elif any(r.get("type") == "Location" for r in vm.get("restrictions") or []):
        out.append(f"{vm_size} 가 리전에서 제한됨")
    else:
        _info(f"SKU {vm_size}: 리전 제한 없음")
    return out


def main(argv: list[str]) -> int:
    if len(argv) != 7:
        print("사용법: <usage.json> <skus.json> <own_dsv5> <own_vm_count> <system_size> <user_size> <vm_size>", file=sys.stderr)
        return 2
    with open(argv[0], encoding="utf-8") as f:
        usage = json.load(f)
    with open(argv[1], encoding="utf-8") as f:
        skus = json.load(f)
    found = problems(usage, skus, int(argv[2]), int(argv[3]), *argv[4:])
    for p in found:
        print(p)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
