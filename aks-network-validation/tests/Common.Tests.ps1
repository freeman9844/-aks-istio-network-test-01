BeforeAll { Import-Module "$PSScriptRoot/../lib/Common.psm1" -Force }

Describe 'Get-CurlCode' {
  It 'run-command 메시지의 stdout 구간에서 코드 추출' {
    $msg = "Enable succeeded: `n[stdout]`n200`n[stderr]`n"
    Get-CurlCode -Output $msg | Should -Be '200'
  }
  It 'stderr 쪽 숫자는 무시' {
    $msg = "Enable succeeded: `n[stdout]`n`n[stderr]`ncurl: (28) Connection timed out after 10001 milliseconds 404`n"
    Get-CurlCode -Output $msg | Should -Be '000'
  }
  It 'kubectl exec 출력(코드만) 그대로' { Get-CurlCode -Output '403' | Should -Be '403' }
  It '연결 실패 000' { Get-CurlCode -Output "000`n" | Should -Be '000' }
  It '빈 출력 → 000' { Get-CurlCode -Output '' | Should -Be '000' }
  It 'null → 000' { Get-CurlCode -Output $null | Should -Be '000' }
  It '코드 없는 출력 → 000' { Get-CurlCode -Output 'error: unable to upgrade connection' | Should -Be '000' }
}

Describe 'Get-FirstIPv4' {
  It 'dig +short: CNAME 다음 첫 IPv4' {
    $out = "staksnetval.privatelink.blob.core.windows.net.`n10.50.2.4"
    Get-FirstIPv4 -Output $out | Should -Be '10.50.2.4'
  }
  It 'getent hosts: 줄 첫 토큰' {
    Get-FirstIPv4 -Output '10.50.2.4       staksnetval.privatelink.blob.core.windows.net' | Should -Be '10.50.2.4'
  }
  It 'IPv6만 있으면 빈 문자열' { Get-FirstIPv4 -Output 'fd00::1  host' | Should -Be '' }
  It '빈 출력 → 빈 문자열' { Get-FirstIPv4 -Output '' | Should -Be '' }
}

Describe 'ConvertFrom-CurlRun' {
  It 'curl 실행됨, 연결 거부(rc=7) → Ran, 000' {
    $r = ConvertFrom-CurlRun -Output "000`nrc=7"
    $r.Ran | Should -BeTrue; $r.Code | Should -Be '000'; $r.Rc | Should -Be 7
  }
  It 'curl 성공 → Ran, 코드' {
    $r = ConvertFrom-CurlRun -Output "403`nrc=0"
    $r.Ran | Should -BeTrue; $r.Code | Should -Be '403'; $r.Rc | Should -Be 0
  }
  It 'rc 줄 없음(exec 실패·Pod 없음) → Ran 거짓, 000' {
    $r = ConvertFrom-CurlRun -Output ''
    $r.Ran | Should -BeFalse; $r.Code | Should -Be '000'; $r.Rc | Should -BeNullOrEmpty
  }
  It 'rc 줄 없이 코드만 있어도 Ran 거짓' {
    (ConvertFrom-CurlRun -Output '000').Ran | Should -BeFalse
  }
  It 'run-command 메시지: stdout 구간의 rc만 인정' {
    $r = ConvertFrom-CurlRun -Output "Enable succeeded: `n[stdout]`n000`nrc=28`n[stderr]`n"
    $r.Ran | Should -BeTrue; $r.Code | Should -Be '000'; $r.Rc | Should -Be 28
  }
  It 'stderr 쪽 rc 줄은 무시' {
    (ConvertFrom-CurlRun -Output "Enable succeeded: `n[stdout]`n`n[stderr]`nrc=0`n").Ran | Should -BeFalse
  }
}

Describe 'ConvertTo-ZoneKey' {
  It "리전 접두사 제거: 'koreacentral-2' → '2'" { ConvertTo-ZoneKey -Zone 'koreacentral-2' | Should -Be '2' }
  It "이미 숫자면 그대로" { ConvertTo-ZoneKey -Zone '3' | Should -Be '3' }
  It "영역 없는 노드(리전 이름만, 숫자 아님) → 빈 문자열" { ConvertTo-ZoneKey -Zone 'koreacentral' | Should -Be '' }
  It "빈 값 → 빈 문자열" { ConvertTo-ZoneKey -Zone '' | Should -Be '' }
  It "null → 빈 문자열" { ConvertTo-ZoneKey -Zone $null | Should -Be '' }
}

Describe 'Get-ZoneNodeCounts' {
  It '영역 레이블 목록을 영역 키별 개수로 집계' {
    $h = Get-ZoneNodeCounts -Zones @('koreacentral-1', 'koreacentral-2', 'koreacentral-1', 'koreacentral-3')
    $h['1'] | Should -Be 2; $h['2'] | Should -Be 1; $h['3'] | Should -Be 1
    $h.Count | Should -Be 3
  }
  It '영역 없는 노드는 집계하지 않음' {
    $h = Get-ZoneNodeCounts -Zones @('koreacentral-1', '', 'koreacentral')
    $h.Count | Should -Be 1; $h['1'] | Should -Be 1
  }
  It '빈 목록 → 빈 hashtable' { (Get-ZoneNodeCounts -Zones @()).Count | Should -Be 0 }
}

Describe 'ConvertFrom-CurlRun: curl 없음/실행 불가' {
  It 'rc=127(curl 없음) → Ran 거짓, 000' {
    $r = ConvertFrom-CurlRun -Output "sh: curl: not found`n`nrc=127"
    $r.Ran | Should -BeFalse; $r.Code | Should -Be '000'; $r.Rc | Should -Be 127
  }
  It 'rc=126(실행 불가) → Ran 거짓' { (ConvertFrom-CurlRun -Output "`nrc=126").Ran | Should -BeFalse }
}

Describe 'Get-VcpuNeed' {
  BeforeAll {
    $script:Cfg = @{ SystemVmSize = 'Standard_D4s_v5'; UserVmSize = 'Standard_D2s_v5'; UserPools = @('a', 'b', 'c'); UserMax = 3; VmSize = 'Standard_B2s_v2' }
  }
  It '새로 만들 때: DSv5 22, Total Regional 26(VM 2대 × 2 포함)' {
    $n = Get-VcpuNeed -Cfg $script:Cfg -OwnDsv5 0 -OwnVmCount 0
    $n.Dsv5 | Should -Be 22; $n.Total | Should -Be 26
  }
  It '재실행: 이미 쓰는 vCPU는 뺀다' {
    $n = Get-VcpuNeed -Cfg $script:Cfg -OwnDsv5 8 -OwnVmCount 2
    $n.Dsv5 | Should -Be 14; $n.Total | Should -Be 14
  }
}
