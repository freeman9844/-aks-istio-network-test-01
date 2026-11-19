Set-StrictMode -Version Latest

function Get-HttpVerdict {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$Code,
    [Parameter(Mandatory)][ValidateSet('200', '403', 'blocked')][string]$Expect,
    [bool]$ControlPassed = $true
  )
  # 대조군이 실패하면 차단의 원인을 알 수 없으므로 결과와 무관하게 INCONCLUSIVE
  if (-not $ControlPassed) { return 'INCONCLUSIVE' }
  $expected = if ($Expect -eq 'blocked') { '000' } else { $Expect }
  if ($Code -eq $expected) { 'PASS' } else { 'FAIL' }
}

function Test-PeIp {
  [CmdletBinding()]
  [OutputType([bool])]
  param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Ip)
  $addr = $null
  if (-not [System.Net.IPAddress]::TryParse($Ip, [ref]$addr)) { return $false }
  if ($addr.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $false }
  $b = $addr.GetAddressBytes()
  # 10.50.2.0/24
  return ($b[0] -eq 10 -and $b[1] -eq 50 -and $b[2] -eq 2)
}

function Get-TlsVerdict {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$ResolvedIp,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Code,
    [Parameter(Mandatory)][ValidateSet('ok', 'fail')][string]$Expect,
    [bool]$ControlPassed = $true
  )
  if (-not $ControlPassed) { return 'INCONCLUSIVE' }
  # DNS가 PE IP로 해석되지 않으면 NetworkPolicy 경로를 검증한 것이 아님
  if (-not (Test-PeIp -Ip $ResolvedIp)) { return 'INCONCLUSIVE' }
  $connected = $Code -ne '000'
  $ok = if ($Expect -eq 'ok') { $connected } else { -not $connected }
  if ($ok) { 'PASS' } else { 'FAIL' }
}

function Get-HpaVerdict {
  [CmdletBinding()]
  param([Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][object[]]$Samples)

  $expectedSeq = @(5, 4, 3, 2)
  $minIntervalSec = 55
  $sorted = @($Samples | Sort-Object { [datetime]$_.Time })

  # 연속 중복 제거: 값이 바뀐 시각만 남긴다
  $seq = [System.Collections.Generic.List[int]]::new()
  $changeTimes = [System.Collections.Generic.List[datetime]]::new()
  foreach ($s in $sorted) {
    $rep = [int]$s.Replicas
    if ($seq.Count -eq 0) { $seq.Add($rep); continue }
    if ($rep -ne $seq[$seq.Count - 1]) {
      $seq.Add($rep)
      $changeTimes.Add([datetime]$s.Time)
    }
  }

  $intervals = [System.Collections.Generic.List[double]]::new()
  for ($i = 1; $i -lt $changeTimes.Count; $i++) {
    $intervals.Add(($changeTimes[$i] - $changeTimes[$i - 1]).TotalSeconds)
  }

  $sequence = [int[]]$seq.ToArray()
  $intervalsSec = [double[]]$intervals.ToArray()
  $seqText = $sequence -join ','

  $reason = $null
  if ($sequence.Count -eq 0) {
    $reason = '표본이 없습니다'
  } elseif ($sequence -notcontains 2) {
    $reason = "레플리카가 2에 도달하지 않았습니다 (관측 순서: $seqText)"
  } elseif ($seqText -ne ($expectedSeq -join ',')) {
    $reason = "레플리카 순서가 5,4,3,2가 아닙니다 (관측 순서: $seqText)"
  } else {
    $short = @($intervalsSec | Where-Object { $_ -lt $minIntervalSec })
    if ($short.Count -gt 0) {
      $reason = "감소 간격이 ${minIntervalSec}초 미만입니다 (간격: $($intervalsSec -join ',')초)"
    }
  }

  $verdict = if ($reason) { 'FAIL' } else { 'PASS' }
  if (-not $reason) { $reason = "5→4→3→2 순서로 감소, 간격 $($intervalsSec -join ',')초" }

  [pscustomobject]@{
    Verdict      = $verdict
    Sequence     = $sequence
    IntervalsSec = $intervalsSec
    Reason       = $reason
  }
}

function Get-ZoneBalanceVerdict {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)][hashtable]$NodesByZone,
    [Parameter(Mandatory, Position = 1)][int]$PendingCount,
    # 확장 전 사용자 노드 총수. 0 이상이면 확장 후 총수가 늘지 않았을 때 INCONCLUSIVE
    [int]$NodesBefore = -1
  )
  # 영역은 '1','2','3' 고정, 없는 영역은 0대
  $counts = foreach ($z in '1', '2', '3') {
    if ($NodesByZone.ContainsKey($z)) { [int]$NodesByZone[$z] } else { 0 }
  }
  $summary = "영역1=$($counts[0]), 영역2=$($counts[1]), 영역3=$($counts[2])"

  # 확장 없이 Pending 이 남는 경우(할당량 부족 등)는 설계 5.8대로 FAIL 이므로 Pending 을 먼저 본다
  if ($PendingCount -gt 0) {
    return [pscustomobject]@{ Verdict = 'FAIL'; Reason = "Pending Pod가 ${PendingCount}개 남아 있습니다 ($summary)" }
  }

  $total = ($counts | Measure-Object -Sum).Sum
  if ($NodesBefore -ge 0 -and $total -le $NodesBefore) {
    return [pscustomobject]@{ Verdict = 'INCONCLUSIVE'; Reason = "CAS 확장 없음: 사용자 노드 $NodesBefore → ${total}대 ($summary)" }
  }
  $stat = $counts | Measure-Object -Maximum -Minimum
  $diff = $stat.Maximum - $stat.Minimum
  if ($diff -le 1) {
    [pscustomobject]@{ Verdict = 'PASS'; Reason = "영역별 노드 수 차이 $diff ≤ 1 ($summary)" }
  } else {
    [pscustomobject]@{ Verdict = 'FAIL'; Reason = "영역별 노드 수 차이 $diff > 1 ($summary)" }
  }
}

function Get-NsgReuseVerdict {
  # T3: nsg-ingress 에 Deny 규칙이 있고 snet-ingress 에 연결된 것이 확인될 때만 T1 판정을 재사용한다
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$T1Verdict,
    # 규칙의 access 값. 규칙이 없으면 ''
    [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$RuleAccess,
    # 서브넷의 networkSecurityGroup.id. 연결이 없으면 ''
    [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$SubnetNsgId,
    [Parameter(Mandatory)][string]$NsgName,
    [Parameter(Mandatory)][string]$RuleName
  )
  if ($RuleAccess -ne 'Deny') {
    $got = if ([string]::IsNullOrEmpty($RuleAccess)) { '없음' } else { "access=$RuleAccess" }
    return [pscustomobject]@{ Verdict = 'INCONCLUSIVE'; Note = "$NsgName/$RuleName Deny 규칙 확인 실패($got): T1 재사용 불가" }
  }
  $attached = if ([string]::IsNullOrEmpty($SubnetNsgId)) { '' } else { ($SubnetNsgId.TrimEnd('/') -split '/')[-1] }
  if ($attached -ne $NsgName) {
    $got = if ($attached) { $attached } else { '없음' }
    return [pscustomobject]@{ Verdict = 'INCONCLUSIVE'; Note = "서브넷 NSG 연결이 $NsgName 이 아님(연결된 NSG: $got): T1 재사용 불가" }
  }
  [pscustomobject]@{ Verdict = $T1Verdict; Note = "$NsgName/$RuleName Deny 규칙과 서브넷 연결 확인, T1 결과 재사용" }
}

function Assert-NotEmpty {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Value,
    [Parameter(Mandatory)][string]$Name
  )
  if ([string]::IsNullOrWhiteSpace($Value)) { throw "$Name 값이 비어 있습니다" }
}

Export-ModuleMember -Function Get-HttpVerdict, Test-PeIp, Get-TlsVerdict, Get-HpaVerdict, Get-ZoneBalanceVerdict, Get-NsgReuseVerdict, Assert-NotEmpty
