import json

from aksnetval.parse import CurlRun, curl_code, curl_run, first_ipv4, main, vcpu_need, zone_counts, zone_key


# curl_code (Get-CurlCode)
def test_curl_code_from_runcommand_stdout():
    assert curl_code("Enable succeeded: \n[stdout]\n200\n[stderr]\n") == "200"


def test_curl_code_ignores_stderr_digits():
    msg = "Enable succeeded: \n[stdout]\n\n[stderr]\ncurl: (28) Connection timed out after 10001 milliseconds 404\n"
    assert curl_code(msg) == "000"


def test_curl_code_plain():
    assert curl_code("403") == "403"


def test_curl_code_000():
    assert curl_code("000\n") == "000"


def test_curl_code_empty():
    assert curl_code("") == "000"


def test_curl_code_none():
    assert curl_code(None) == "000"


def test_curl_code_no_code():
    assert curl_code("error: unable to upgrade connection") == "000"


# first_ipv4 (Get-FirstIPv4)
def test_first_ipv4_dig_after_cname():
    assert first_ipv4("staksnetval.privatelink.blob.core.windows.net.\n10.50.2.4") == "10.50.2.4"


def test_first_ipv4_getent():
    assert first_ipv4("10.50.2.4       staksnetval.privatelink.blob.core.windows.net") == "10.50.2.4"


def test_first_ipv4_ipv6_only():
    assert first_ipv4("fd00::1  host") == ""


def test_first_ipv4_empty():
    assert first_ipv4("") == ""


# curl_run (ConvertFrom-CurlRun)
def test_curl_run_refused():
    assert curl_run("000\nrc=7") == CurlRun(True, "000", 7)


def test_curl_run_success():
    assert curl_run("403\nrc=0") == CurlRun(True, "403", 0)


def test_curl_run_no_rc_line():
    assert curl_run("") == CurlRun(False, "000", None)


def test_curl_run_code_without_rc_not_ran():
    assert curl_run("000").ran is False


def test_curl_run_runcommand_stdout_rc_only():
    assert curl_run("Enable succeeded: \n[stdout]\n000\nrc=28\n[stderr]\n") == CurlRun(True, "000", 28)


def test_curl_run_ignores_stderr_rc():
    assert curl_run("Enable succeeded: \n[stdout]\n\n[stderr]\nrc=0\n").ran is False


def test_curl_run_rc127_not_ran():
    assert curl_run("sh: curl: not found\n\nrc=127") == CurlRun(False, "000", 127)


def test_curl_run_rc126_not_ran():
    assert curl_run("\nrc=126").ran is False


# zone_key / zone_counts
def test_zone_key_strips_region():
    assert zone_key("koreacentral-2") == "2"


def test_zone_key_digit():
    assert zone_key("3") == "3"


def test_zone_key_region_only():
    assert zone_key("koreacentral") == ""


def test_zone_key_empty():
    assert zone_key("") == ""


def test_zone_key_none():
    assert zone_key(None) == ""


def test_zone_counts():
    assert zone_counts(["koreacentral-1", "koreacentral-2", "koreacentral-1", "koreacentral-3"]) == {"1": 2, "2": 1, "3": 1}


def test_zone_counts_skips_zoneless():
    assert zone_counts(["koreacentral-1", "", "koreacentral"]) == {"1": 1}


def test_zone_counts_empty():
    assert zone_counts([]) == {}


# vcpu_need: vm-mgmt 포함 B2s_v2 3대
def test_vcpu_need_fresh():
    n = vcpu_need(0, 0)
    assert (n["dsv5"], n["bsv2"], n["total"]) == (22, 6, 28)


def test_vcpu_need_rerun_subtracts_own():
    n = vcpu_need(own_dsv5=8, own_vm_count=3)
    assert (n["dsv5"], n["bsv2"], n["total"]) == (14, 0, 14)


def test_cli_prints_json(capsys):
    assert main(["curl_run", '{"output": "403\\nrc=0"}']) == 0
    assert json.loads(capsys.readouterr().out) == {"ran": True, "code": "403", "rc": 0}
