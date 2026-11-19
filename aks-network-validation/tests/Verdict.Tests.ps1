BeforeAll { Import-Module "$PSScriptRoot/../lib/Verdict.psm1" -Force }

Describe 'Get-HttpVerdict' {
  It '기대 200, 받음 200 → PASS'  { Get-HttpVerdict -Code '200' -Expect '200' | Should -Be 'PASS' }
  It '기대 403, 받음 200 → FAIL'  { Get-HttpVerdict -Code '200' -Expect '403' | Should -Be 'FAIL' }
  It '차단 기대, 000 → PASS'      { Get-HttpVerdict -Code '000' -Expect 'blocked' | Should -Be 'PASS' }
  It '대조군 실패 → INCONCLUSIVE' { Get-HttpVerdict -Code '000' -Expect 'blocked' -ControlPassed $false | Should -Be 'INCONCLUSIVE' }
}
Describe 'Get-TlsVerdict' {
  It 'PE IP + 000 + fail 기대 → PASS' { Get-TlsVerdict -ResolvedIp '10.50.2.4' -Code '000' -Expect 'fail' | Should -Be 'PASS' }
  It 'PE IP + 400 + ok 기대 → PASS'   { Get-TlsVerdict -ResolvedIp '10.50.2.4' -Code '400' -Expect 'ok' | Should -Be 'PASS' }
  It '공인 IP 해석 → INCONCLUSIVE'    { Get-TlsVerdict -ResolvedIp '20.1.2.3' -Code '000' -Expect 'fail' | Should -Be 'INCONCLUSIVE' }
  It '10.50.20.4는 PE 아님'           { Test-PeIp '10.50.20.4' | Should -BeFalse }
}
Describe 'Get-HpaVerdict' {
  BeforeAll { function S($p){ $t0=[datetime]'2026-01-01'; $p | % { [pscustomobject]@{Time=$t0.AddSeconds($_[0]);Replicas=$_[1]} } } }
  It '5,5,4,4,3,2 / 60초 간격 → PASS' {
    $r = Get-HpaVerdict (S @(@(0,5),@(10,5),@(60,4),@(90,4),@(120,3),@(180,2)))
    $r.Verdict | Should -Be 'PASS'; $r.Sequence | Should -Be @(5,4,3,2) }
  It '간격 30초 → FAIL'  { (Get-HpaVerdict (S @(@(0,5),@(60,4),@(90,3),@(150,2)))).Verdict | Should -Be 'FAIL' }
  It '5→3 건너뜀 → FAIL' { (Get-HpaVerdict (S @(@(0,5),@(60,3),@(120,2)))).Verdict | Should -Be 'FAIL' }
  It '2 미도달 → FAIL, 사유에 2' { $r=Get-HpaVerdict (S @(@(0,5),@(60,4))); $r.Verdict | Should -Be 'FAIL'; $r.Reason | Should -Match '2' }
}
Describe 'Get-ZoneBalanceVerdict' {
  It '2/2/2 → PASS'            { (Get-ZoneBalanceVerdict @{'1'=2;'2'=2;'3'=2} 0).Verdict | Should -Be 'PASS' }
  It '3/2/1 → FAIL'            { (Get-ZoneBalanceVerdict @{'1'=3;'2'=2;'3'=1} 0).Verdict | Should -Be 'FAIL' }
  It '영역 누락은 0으로 → FAIL' { (Get-ZoneBalanceVerdict @{'1'=3;'2'=3} 0).Verdict | Should -Be 'FAIL' }
  It 'Pending 남음 → FAIL+사유' { $r=Get-ZoneBalanceVerdict @{'1'=2;'2'=2;'3'=2} 1; $r.Verdict | Should -Be 'FAIL'; $r.Reason | Should -Match 'Pending' }
}
Describe 'Assert-NotEmpty' {
  It '빈 값이면 throw' { { Assert-NotEmpty -Value '' -Name 'GatewaySA' } | Should -Throw '*GatewaySA*' }
}

Describe 'Get-NsgReuseVerdict (T3)' {
  BeforeAll { $script:Id = '/subscriptions/x/resourceGroups/rg/providers/Microsoft.Network/networkSecurityGroups/nsg-ingress' }
  It 'Deny 규칙 있고 서브넷 연결 맞음 → T1 판정 재사용' {
    $r = Get-NsgReuseVerdict -T1Verdict 'PASS' -RuleAccess 'Deny' -SubnetNsgId $script:Id -NsgName 'nsg-ingress' -RuleName 'deny-appgw-all'
    $r.Verdict | Should -Be 'PASS'; $r.Note | Should -Match 'deny-appgw-all'
  }
  It '확인 통과 + T1 FAIL → FAIL' {
    (Get-NsgReuseVerdict -T1Verdict 'FAIL' -RuleAccess 'Deny' -SubnetNsgId $script:Id -NsgName 'nsg-ingress' -RuleName 'deny-appgw-all').Verdict | Should -Be 'FAIL'
  }
  It 'Deny 규칙 없음 → INCONCLUSIVE, 사유에 규칙 이름' {
    $r = Get-NsgReuseVerdict -T1Verdict 'PASS' -RuleAccess '' -SubnetNsgId $script:Id -NsgName 'nsg-ingress' -RuleName 'deny-appgw-all'
    $r.Verdict | Should -Be 'INCONCLUSIVE'; $r.Note | Should -Match 'deny-appgw-all'
  }
  It '규칙이 Allow → INCONCLUSIVE' {
    (Get-NsgReuseVerdict -T1Verdict 'PASS' -RuleAccess 'Allow' -SubnetNsgId $script:Id -NsgName 'nsg-ingress' -RuleName 'deny-appgw-all').Verdict | Should -Be 'INCONCLUSIVE'
  }
  It '서브넷에 다른 NSG 연결 → INCONCLUSIVE' {
    $r = Get-NsgReuseVerdict -T1Verdict 'PASS' -RuleAccess 'Deny' -SubnetNsgId ($script:Id + '-old') -NsgName 'nsg-ingress' -RuleName 'deny-appgw-all'
    $r.Verdict | Should -Be 'INCONCLUSIVE'; $r.Note | Should -Match '서브넷'
  }
  It '서브넷에 NSG 없음 → INCONCLUSIVE' {
    (Get-NsgReuseVerdict -T1Verdict 'PASS' -RuleAccess 'Deny' -SubnetNsgId '' -NsgName 'nsg-ingress' -RuleName 'deny-appgw-all').Verdict | Should -Be 'INCONCLUSIVE'
  }
}
Describe 'Get-ZoneBalanceVerdict -NodesBefore' {
  It '확장 전후 총 노드 수 같음 → INCONCLUSIVE(CAS 확장 없음)' {
    $r = Get-ZoneBalanceVerdict @{'1'=1;'2'=1;'3'=1} 0 -NodesBefore 3
    $r.Verdict | Should -Be 'INCONCLUSIVE'; $r.Reason | Should -Match 'CAS 확장 없음'
  }
  It '확장 없음 + Pending 남음(할당량 부족 등) → FAIL' {
    $r = Get-ZoneBalanceVerdict @{'1'=1;'2'=1;'3'=1} 2 -NodesBefore 3
    $r.Verdict | Should -Be 'FAIL'; $r.Reason | Should -Match 'Pending'
  }
  It '확장 후 총 노드 수 증가 + 균형 → PASS' { (Get-ZoneBalanceVerdict @{'1'=2;'2'=2;'3'=2} 0 -NodesBefore 3).Verdict | Should -Be 'PASS' }
}
