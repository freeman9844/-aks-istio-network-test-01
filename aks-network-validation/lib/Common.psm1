# 공통 헬퍼: az 호출, 구독 확인, 사전 점검, 전용 kubeconfig

Set-StrictMode -Version Latest

$script:NotFoundPattern = 'ResourceNotFound|ResourceGroupNotFound|NotFound|was not found|could not be found|does not exist'

function Invoke-Az {
  [CmdletBinding()]
  param([Parameter(Mandatory, Position = 0)][string[]]$Arguments)

  $stdout = [System.Collections.Generic.List[string]]::new()
  $stderr = [System.Collections.Generic.List[string]]::new()
  & az @Arguments 2>&1 | ForEach-Object {
    if ($_ -is [System.Management.Automation.ErrorRecord]) { $stderr.Add($_.ToString()) }
    else { $stdout.Add([string]$_) }
  }
  $code = $LASTEXITCODE
  # 인수에는 비밀이 없지만 오류 메시지에는 명령 앞부분만 남긴다
  $cmd = 'az ' + (($Arguments | Select-Object -First 3) -join ' ')
  if ($code -ne 0) {
    $err = ($stderr -join "`n").Trim()
    $ex = [System.Exception]::new("$cmd 실패(종료 코드 $code): $err")
    $ex.Data['AzStdErr'] = $err
    throw $ex
  }
  $text = ($stdout -join "`n").Trim()
  if ([string]::IsNullOrEmpty($text)) { return $null }
  if ($text.StartsWith('{') -or $text.StartsWith('[')) {
    try { return ($text | ConvertFrom-Json -Depth 100) } catch { return $text }
  }
  return $text
}

function Test-AzResource {
  # az <type> show 가 성공하면 $true, NotFound 계열이면 $false, 그 밖의 오류는 다시 throw
  [CmdletBinding()]
  param([Parameter(Mandatory, Position = 0)][string[]]$Arguments)
  try {
    $res = Invoke-Az ($Arguments + @('-o', 'json'))
    # 일부 show 명령(dns-zone-group 등)은 없을 때 종료 코드 0과 {} 를 돌려준다
    if ($null -eq $res) { return $false }
    if ($res -is [psobject] -and -not ($res -is [string]) -and @($res.PSObject.Properties).Count -eq 0) { return $false }
    return $true
  } catch {
    $msg = if ($_.Exception.Data.Contains('AzStdErr')) { $_.Exception.Data['AzStdErr'] } else { $_.Exception.Message }
    if ($msg -match $script:NotFoundPattern) { return $false }
    throw
  }
}

function Confirm-Subscription {
  [CmdletBinding()]
  param([switch]$Force)
  $name = Invoke-Az @('account', 'show', '--query', 'name', '-o', 'tsv')
  if ([string]::IsNullOrWhiteSpace($name)) { throw '현재 구독 이름을 확인할 수 없습니다' }
  Write-Host "현재 구독: $name"
  if ($Force) { return }
  $answer = Read-Host '이 구독에 리소스를 만들까요? (y/N)'
  if ($answer -ne 'y') {
    Write-Host '중단: 아무것도 만들지 않았습니다'
    exit 1
  }
}

function Get-OwnClusterVcpu {
  # 재실행 시 이미 이 클러스터가 쓰는 vCPU는 필요량에서 뺀다
  param([hashtable]$Cfg)
  $result = @{ DSv5 = 0 }
  if (-not (Test-AzResource @('aks', 'show', '-g', $Cfg.ResourceGroup, '-n', $Cfg.Aks, '--query', 'id'))) { return $result }
  $pools = Invoke-Az @('aks', 'nodepool', 'list', '-g', $Cfg.ResourceGroup, '--cluster-name', $Cfg.Aks, '-o', 'json')
  foreach ($p in @($pools)) {
    $cores = switch ($p.vmSize) { 'Standard_D4s_v5' { 4 } 'Standard_D2s_v5' { 2 } default { 0 } }
    $result.DSv5 += $cores * [int]$p.count
  }
  return $result
}

$script:SizeCores = @{ 'Standard_D4s_v5' = 4; 'Standard_D2s_v5' = 2; 'Standard_B2s_v2' = 2 }
$script:TestVmCount = 2

function Get-VcpuNeed {
  # 최대 구성 기준 필요 vCPU에서 이미 쓰는 양을 뺀다. Dsv5: AKS 노드, Total: AKS 노드 + 트래픽 출발지 VM
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$Cfg,
    [int]$OwnDsv5 = 0,
    [int]$OwnVmCount = 0
  )
  $maxDsv5 = $script:SizeCores[$Cfg.SystemVmSize] + $Cfg.UserPools.Count * $Cfg.UserMax * $script:SizeCores[$Cfg.UserVmSize]
  $vmCores = $script:SizeCores[$Cfg.VmSize]
  $maxTotal = $maxDsv5 + $script:TestVmCount * $vmCores
  [pscustomobject]@{
    MaxDsv5  = $maxDsv5
    MaxTotal = $maxTotal
    Dsv5     = [Math]::Max(0, $maxDsv5 - $OwnDsv5)
    Total    = [Math]::Max(0, $maxTotal - $OwnDsv5 - $OwnVmCount * $vmCores)
  }
}

function Test-Preflight {
  [CmdletBinding()]
  param([Parameter(Mandatory, Position = 0)][hashtable]$Cfg)

  $problems = [System.Collections.Generic.List[string]]::new()
  $own = Get-OwnClusterVcpu -Cfg $Cfg
  $ownVms = @($Cfg.VmAppgw, $Cfg.VmOther | Where-Object { Test-AzResource @('vm', 'show', '-g', $Cfg.ResourceGroup, '-n', $_, '--query', 'id') }).Count
  $vn = Get-VcpuNeed -Cfg $Cfg -OwnDsv5 $own.DSv5 -OwnVmCount $ownVms
  $maxNeed = $vn.MaxDsv5
  $need = $vn.Dsv5

  $usage = @(Invoke-Az @('vm', 'list-usage', '-l', $Cfg.Location, '-o', 'json'))
  $dsv5 = $usage | Where-Object { $_.name.value -eq 'standardDSv5Family' } | Select-Object -First 1
  if (-not $dsv5) {
    $problems.Add('Standard DSv5 Family 할당량 정보를 찾을 수 없음')
  } else {
    $free = [int]$dsv5.limit - [int]$dsv5.currentValue
    Write-Host ("할당량 Standard DSv5 Family: 사용 {0} / 한도 {1}, 잔여 {2} vCPU (필요 {3}, 최대 {4} 중 이 클러스터 사용분 {5} 제외)" -f $dsv5.currentValue, $dsv5.limit, $free, $need, $maxNeed, $own.DSv5)
    if ($free -lt $need) { $problems.Add("Standard DSv5 Family 잔여 vCPU $free < 필요 $need") }
  }
  $total = $usage | Where-Object { $_.name.value -eq 'cores' } | Select-Object -First 1
  if ($total) {
    $tfree = [int]$total.limit - [int]$total.currentValue
    Write-Host ("할당량 Total Regional vCPUs: 잔여 {0} (필요 {1}, 최대 {2} = AKS {3} + VM {4}대 중 기존 VM {5}대 포함 이미 쓰는 분 제외)" -f $tfree, $vn.Total, $vn.MaxTotal, $vn.MaxDsv5, $script:TestVmCount, $ownVms)
    if ($tfree -lt $vn.Total) { $problems.Add("Total Regional vCPUs 잔여 $tfree < 필요 $($vn.Total)") }
  }

  $skus = @(Invoke-Az @('vm', 'list-skus', '-l', $Cfg.Location, '--resource-type', 'virtualMachines', '--size', 'Standard_D', '-o', 'json'))
  foreach ($size in @($Cfg.SystemVmSize, $Cfg.UserVmSize) | Select-Object -Unique) {
    $sku = $skus | Where-Object { $_.name -eq $size } | Select-Object -First 1
    if (-not $sku) { $problems.Add("$size 가 $($Cfg.Location)에 없음"); continue }
    $zones = @($sku.locationInfo | ForEach-Object { $_.zones } | Where-Object { $_ })
    $restricted = @()
    foreach ($r in @($sku.restrictions)) {
      if (-not $r) { continue }
      if ($r.type -eq 'Location') { $restricted += '1', '2', '3' }
      elseif ($r.type -eq 'Zone') { $restricted += @($r.restrictionInfo.zones) }
    }
    $bad = @('1', '2', '3' | Where-Object { $_ -notin $zones -or $_ -in $restricted })
    if ($bad.Count -gt 0) {
      $problems.Add("$size 영역 $($bad -join ',') 사용 불가(제한 또는 미제공)")
    } else {
      Write-Host "SKU ${size}: 영역 1·2·3 제한 없음"
    }
  }

  # 트래픽 출발지 VM(영역 지정 없음): 리전에 제공되고 리전 제한이 없어야 한다
  $vmSku = @(Invoke-Az @('vm', 'list-skus', '-l', $Cfg.Location, '--resource-type', 'virtualMachines', '--size', $Cfg.VmSize, '-o', 'json')) |
    Where-Object { $_.name -eq $Cfg.VmSize } | Select-Object -First 1
  if (-not $vmSku) {
    $problems.Add("$($Cfg.VmSize) 가 $($Cfg.Location)에 없음")
  } elseif (@($vmSku.restrictions | Where-Object { $_ -and $_.type -eq 'Location' }).Count -gt 0) {
    $problems.Add("$($Cfg.VmSize) 가 $($Cfg.Location)에서 제한됨")
  } else {
    Write-Host "SKU $($Cfg.VmSize): 리전 제한 없음"
  }

  if ($problems.Count -gt 0) {
    throw ("사전 점검 실패: " + ($problems -join '; '))
  }
  Write-Host '사전 점검 통과'
}

function Get-AksKubeconfig {
  [CmdletBinding()]
  param([Parameter(Mandatory, Position = 0)][hashtable]$Cfg)
  if (-not (Test-Path $Cfg.ResultsDir)) { $null = New-Item -ItemType Directory -Path $Cfg.ResultsDir }
  $path = Join-Path $Cfg.ResultsDir '.kubeconfig'
  $null = Invoke-Az @('aks', 'get-credentials', '-g', $Cfg.ResourceGroup, '-n', $Cfg.Aks, '--file', $path, '--overwrite-existing')
  # Pod 헬퍼(Invoke-PodCurl, Resolve-PodDns)는 이 전용 kubeconfig만 쓴다
  $script:Kubeconfig = $path
  $script:ResourceGroup = $Cfg.ResourceGroup
  $script:ResultsDir = $Cfg.ResultsDir
  return $path
}

$script:Kubeconfig = $null
$script:ResourceGroup = $null
$script:ResultsDir = $null
$script:CurlArgs = "-s -o /dev/null -w '%{http_code}' -m 10"

function Get-CurlCode {
  # curl -w '%{http_code}' 출력(또는 run-command 메시지)에서 3자리 코드만 뽑는다. 못 찾으면 항상 '000'
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Output)
  if ([string]::IsNullOrWhiteSpace($Output)) { return '000' }
  $text = $Output
  $m = [regex]::Match($text, '(?s)\[stdout\](.*?)(\[stderr\]|$)')
  if ($m.Success) { $text = $m.Groups[1].Value }
  $codes = [regex]::Matches($text, '(?m)^\s*(\d{3})\s*$')
  if ($codes.Count -eq 0) { return '000' }
  return $codes[$codes.Count - 1].Groups[1].Value
}

function Get-FirstIPv4 {
  # dig +short / getent hosts 출력에서 줄 첫 토큰이 IPv4인 첫 값. 없으면 ''
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Output)
  if ([string]::IsNullOrWhiteSpace($Output)) { return '' }
  foreach ($line in $Output -split "`r?`n") {
    $tok = ($line.Trim() -split '\s+')[0]
    $addr = $null
    if ($tok -match '^\d{1,3}(\.\d{1,3}){3}$' -and [System.Net.IPAddress]::TryParse($tok, [ref]$addr)) { return $tok }
  }
  return ''
}

function ConvertFrom-CurlRun {
  # curl 뒤에 'rc=<종료코드>' 줄을 찍게 해서, curl이 실제로 실행된 경우(Ran)와 exec/run-command 실패를 구분한다.
  # rc 줄이 없으면 curl이 돌지 않은 것이므로 Ran=$false, Code='000'
  [CmdletBinding()]
  param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Output)
  $text = if ($null -eq $Output) { '' } else { $Output }
  $m = [regex]::Match($text, '(?s)\[stdout\](.*?)(\[stderr\]|$)')
  if ($m.Success) { $text = $m.Groups[1].Value }
  $rcm = [regex]::Match($text, '(?m)^\s*rc=(\d+)\s*$')
  if (-not $rcm.Success) { return [pscustomobject]@{ Ran = $false; Code = '000'; Rc = $null } }
  $rc = [int]$rcm.Groups[1].Value
  # 셸 종료 코드 126(실행 불가)·127(명령 없음)은 curl 자체가 돌지 않은 것
  if ($rc -in 126, 127) { return [pscustomobject]@{ Ran = $false; Code = '000'; Rc = $rc } }
  [pscustomobject]@{ Ran = $true; Code = (Get-CurlCode -Output $text); Rc = $rc }
}

function ConvertTo-ZoneKey {
  # 노드 레이블 topology.kubernetes.io/zone('koreacentral-1')을 Get-ZoneBalanceVerdict 키('1')로. 영역 없는 노드는 ''
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Zone)
  $m = [regex]::Match([string]$Zone, '^(?:.*-)?(\d+)$')
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}

function Get-ZoneNodeCounts {
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Zones)
  $h = @{}
  foreach ($z in $Zones) {
    $k = ConvertTo-ZoneKey -Zone $z
    if (-not $k) { continue }
    if ($h.ContainsKey($k)) { $h[$k]++ } else { $h[$k] = 1 }
  }
  return $h
}

function Assert-Kubeconfig {
  if (-not $script:Kubeconfig) { throw 'kubeconfig 미준비: Get-AksKubeconfig 를 먼저 호출하세요' }
}

function Invoke-PodExec {
  # 앱 컨테이너(app)에서 sh -c 실행. 종료 코드와 무관하게 stdout 문자열을 돌려준다(curl 시간 초과도 000을 출력)
  param([string]$Namespace, [string]$Deploy, [string]$Script)
  Assert-Kubeconfig
  $out = & kubectl --kubeconfig $script:Kubeconfig exec -n $Namespace "deploy/$Deploy" -c app -- sh -c $Script 2>$null
  return (@($out) -join "`n")
}

function Invoke-VmCurl {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][string]$Vm,
    [Parameter(Mandatory)][string]$Url,
    [string]$HostHeader,
    [switch]$Insecure,
    [string]$ResourceGroup = $script:ResourceGroup,
    # 코드 대신 ConvertFrom-CurlRun 결과(Ran/Code/Rc)를 돌려준다
    [switch]$Detailed
  )
  if (-not $ResourceGroup) { throw '리소스 그룹 미지정: -ResourceGroup 또는 Get-AksKubeconfig 선행' }
  $cmd = "curl $script:CurlArgs"
  if ($Insecure) { $cmd += ' -k' }
  if ($HostHeader) { $cmd += " -H 'Host: $HostHeader'" }
  $cmd += " '$Url'; rc=`$?; echo; echo rc=`$rc"
  $msg = ''
  try {
    $msg = [string](Invoke-Az @('vm', 'run-command', 'invoke', '-g', $ResourceGroup, '-n', $Vm, '--command-id', 'RunShellScript',
        '--scripts', $cmd, '--query', 'value[0].message', '-o', 'tsv'))
  } catch {
    Write-Warning "run-command 실패($Vm): $($_.Exception.Message)"
  }
  $run = ConvertFrom-CurlRun -Output $msg
  if (-not $run.Ran) { Write-Warning "VM $Vm 에서 curl 이 실행되지 않았습니다(run-command 실패)" }
  if ($Detailed) { return $run }
  return $run.Code
}

function Invoke-PodCurl {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][string]$Namespace,
    [Parameter(Mandatory)][string]$Deploy,
    [Parameter(Mandatory)][string]$Url,
    [switch]$Insecure,
    # 코드 대신 ConvertFrom-CurlRun 결과(Ran/Code/Rc)를 돌려준다
    [switch]$Detailed
  )
  $cmd = "curl $script:CurlArgs"
  if ($Insecure) { $cmd += ' -k' }
  $cmd += " '$Url'; rc=`$?; echo; echo rc=`$rc"
  $run = ConvertFrom-CurlRun -Output (Invoke-PodExec -Namespace $Namespace -Deploy $Deploy -Script $cmd)
  if (-not $run.Ran) { Write-Warning "$Namespace/$Deploy 에서 curl 이 실행되지 않았습니다(kubectl exec 실패: Pod·컨테이너 없음 또는 API 오류)" }
  if ($Detailed) { return $run }
  return $run.Code
}

function Resolve-PodDns {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][string]$Namespace,
    [Parameter(Mandatory)][string]$Deploy,
    [Parameter(Mandatory)][string]$Fqdn
  )
  $out = Invoke-PodExec -Namespace $Namespace -Deploy $Deploy -Script "dig +short '$Fqdn' A 2>/dev/null; getent hosts '$Fqdn' 2>/dev/null"
  return (Get-FirstIPv4 -Output $out)
}

function Save-Results {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results,
    [string]$ResultsDir = $script:ResultsDir
  )
  if (-not $ResultsDir) { throw '결과 디렉터리 미지정' }
  if (-not (Test-Path $ResultsDir)) { $null = New-Item -ItemType Directory -Path $ResultsDir }
  $cols = 'Id', 'From', 'To', 'Expect', 'Observed', 'Verdict', 'Note'
  $rows = @($Results | Select-Object -Property $cols)
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $json = Join-Path $ResultsDir "$stamp.json"
  $md = Join-Path $ResultsDir "$stamp.md"
  ConvertTo-Json -InputObject $rows -Depth 5 | Set-Content -Path $json -Encoding utf8
  $esc = { param($v) ([string]$v) -replace '\|', '\|' -replace "`r?`n", ' ' }
  $lines = [System.Collections.Generic.List[string]]::new()
  $lines.Add("# 검증 결과 $stamp")
  $lines.Add('')
  $lines.Add('| ' + ($cols -join ' | ') + ' |')
  $lines.Add('|' + ((1..$cols.Count | ForEach-Object { '---' }) -join '|') + '|')
  foreach ($r in $rows) {
    $lines.Add('| ' + (($cols | ForEach-Object { & $esc $r.$_ }) -join ' | ') + ' |')
  }
  Set-Content -Path $md -Value $lines -Encoding utf8
  $rows | Format-Table -AutoSize -Wrap | Out-Host
  Write-Host "결과 저장: $json, $md"
  return [pscustomobject]@{ Json = $json; Markdown = $md }
}

Export-ModuleMember -Function Invoke-Az, Test-AzResource, Confirm-Subscription, Get-VcpuNeed, Test-Preflight, Get-AksKubeconfig,
  Get-CurlCode, Get-FirstIPv4, ConvertFrom-CurlRun, ConvertTo-ZoneKey, Get-ZoneNodeCounts, Invoke-VmCurl, Invoke-PodCurl, Resolve-PodDns, Save-Results
