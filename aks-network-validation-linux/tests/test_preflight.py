import copy

import pytest

from aksnetval.preflight import problems


def _usage(dsv5=100, bsv2=100, cores=200, include_cores=True):
    u = [
        {"name": {"value": "standardDSv5Family"}, "currentValue": 0, "limit": dsv5},
        {"name": {"value": "standardBSv2Family"}, "currentValue": 0, "limit": bsv2},
    ]
    if include_cores:
        u.append({"name": {"value": "cores"}, "currentValue": 0, "limit": cores})
    return u


def _sku(name, restrictions=None):
    return {"name": name, "locationInfo": [{"location": "koreacentral", "zones": ["1", "2", "3"]}], "restrictions": restrictions or []}


SKUS = [_sku("Standard_D4s_v5"), _sku("Standard_D2s_v5"), _sku("Standard_B2s_v2")]
SIZES = dict(system_size="Standard_D4s_v5", user_size="Standard_D2s_v5", vm_size="Standard_B2s_v2")


def call(usage=None, skus=None, own_dsv5=0, own_vm_count=0):
    return problems(usage if usage is not None else _usage(), skus if skus is not None else SKUS, own_dsv5, own_vm_count, **SIZES)


def test_enough_quota_no_problems():
    assert call() == []


def test_dsv5_short():
    p = call(_usage(dsv5=21))
    assert any("Standard DSv5 Family" in x for x in p)


def test_dsv5_own_usage_subtracted():
    # 이 클러스터가 이미 10 vCPU 를 쓰고 있으면 필요량은 12, 잔여 12 로 충분
    u = _usage(dsv5=22)
    u[0]["currentValue"] = 10
    assert call(u, own_dsv5=10) == []


def test_bsv2_short():
    p = call(_usage(bsv2=4))
    assert any("BSv2" in x for x in p)


def test_quota_name_match_is_case_insensitive():
    # 실제 koreacentral 응답은 "standardBsv2Family"(소문자 sv2)
    u = _usage()
    u[1]["name"]["value"] = "standardBsv2Family"
    assert call(u) == []


def test_total_short():
    p = call(_usage(cores=27))
    assert any("Total Regional vCPUs" in x for x in p)


def test_missing_cores_skips_total_check():
    assert call(_usage(include_cores=False)) == []


def test_missing_dsv5_entry():
    u = [x for x in _usage() if x["name"]["value"] != "standardDSv5Family"]
    assert any("DSv5" in x for x in call(u))


def test_zone_restriction():
    skus = copy.deepcopy(SKUS)
    skus[1]["restrictions"] = [{"type": "Zone", "restrictionInfo": {"zones": ["2"]}}]
    assert any("영역 2" in x for x in call(skus=skus))


def test_vm_sku_location_restricted():
    skus = copy.deepcopy(SKUS)
    skus[2]["restrictions"] = [{"type": "Location", "restrictionInfo": {"locations": ["koreacentral"]}}]
    assert any("제한됨" in x for x in call(skus=skus))


def test_sku_missing():
    assert any("Standard_D4s_v5" in x and "없음" in x for x in call(skus=SKUS[1:]))
