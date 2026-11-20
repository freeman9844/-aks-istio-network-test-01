#Requires -Version 7
# 검증 실행. 전용 kubeconfig(results/.kubeconfig)만 쓰고 현재 kubectl 컨텍스트는 바꾸지 않는다.
# 사용: ./03-verify.ps1 [-Only All|Network|Hpa|Floor|Zone|Spread] [-ResourceGroup <이름>]
[CmdletBinding()]
param(
  [ValidateSet('All', 'Network', 'Hpa', 'Floor', 'Zone', 'Spread')][string]$Only = 'All',
  [string]$ResourceGroup
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'config.ps1')
Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/Verdict.psm1') -Force

# az aks install-cli 기본 설치 위치
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
  $cliDir = Join-Path $env:USERPROFILE '.azure-kubectl'
  if (Test-Path (Join-Path $cliDir 'kubectl.exe')) { $env:Path = "$cliDir;$env:Path" }
  else { throw 'kubectl 을 찾을 수 없습니다: az aks install-cli 로 설치하세요' }
}

$Kubeconfig = Get-AksKubeconfig -Cfg $Cfg
$Results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
  param([string]$Id, [string]$From, [string]$To, [string]$Expect, [string]$Observed, [string]$Verdict, [string]$Note = '')
  $r = [pscustomobject]@{ Id = $Id; From = $From; To = $To; Expect = $Expect; Observed = $Observed; Verdict = $Verdict; Note = $Note }
  $Results.Add($r)
  Write-Host ("[{0}] {1}: 관측 {2} → {3}" -f $Id, $To, $Observed, $Verdict)
  return $r
}

function Get-ControlNote {
  # 대조군 중 PASS가 아닌 것이 있으면 사유 문자열, 모두 PASS면 ''
  param([object[]]$Controls)
  $bad = @($Controls | Where-Object { $_.Verdict -ne 'PASS' })
  if ($bad.Count -eq 0) { return '' }
  return '대조군 실패: ' + (($bad | ForEach-Object { "$($_.Id)=$($_.Verdict)" }) -join ', ')
}

function Join-Note { param([string[]]$Parts) (@($Parts) | Where-Object { $_ }) -join '; ' }

function Get-RunNote {
  # 차단(000) 기대 행: curl 이 실제로 실행되지 않았으면 000 이 차단 증거가 아니므로 사유를 남긴다
  param($Run)
  if (-not $Run.Ran) {
    if ($Run.Rc -in 126, 127) { return "curl 없음/실행 불가(rc=$($Run.Rc)) → 차단 판정 불가" }
    return 'curl 미실행(exec/run-command 실패) → 차단 판정 불가'
  }
  return "curl rc=$($Run.Rc)"
}

function Invoke-NetworkTests {
  $ingressUrl = "http://$($Cfg.IngressIp)/"
  $ingressHost = 'web-a.test'
  $blobFqdn = "$($Cfg.Storage).blob.core.windows.net"
  $blobUrl = "https://$blobFqdn/"
  $svc = { param($name, $ns) "http://$name.$ns.svc.cluster.local:8080/" }
  $bffA = & $svc 'bff-a' 'app'
  $bffB = & $svc 'bff-b' 'app'
  $webB = & $svc 'web-b' 'web'

  Write-Host '== 대조군 =='
  $code = Invoke-VmCurl -Vm $Cfg.VmAppgw -Url $ingressUrl -HostHeader $ingressHost
  $t1 = Add-Result 'T1' "VM $($Cfg.VmAppgw)" "$($Cfg.IngressIp):80 Host $ingressHost" '200' $code (Get-HttpVerdict -Code $code -Expect '200')

  # 같은 VM·run-command 경로가 정상인지: 스토리지의 HTTP 오류 코드도 연결 성공으로 본다
  $code = Invoke-VmCurl -Vm $Cfg.VmOther -Url $blobUrl -Insecure
  $v = if ($code -ne '000') { 'PASS' } else { 'FAIL' }
  $t2c = Add-Result 'T2c' "VM $($Cfg.VmOther)" "${blobFqdn}:443 (TLS)" '연결 성공(≠000)' $code $v

  $code = Invoke-PodCurl -Namespace 'web' -Deploy 'web-a' -Url $bffA
  $t4 = Add-Result 'T4' 'web/web-a' 'bff-a:8080' '200' $code (Get-HttpVerdict -Code $code -Expect '200')

  $code = Invoke-PodCurl -Namespace 'web' -Deploy 'web-b' -Url $bffB
  $t6 = Add-Result 'T6' 'web/web-b' 'bff-b:8080' '200' $code (Get-HttpVerdict -Code $code -Expect '200')

  $ip = Resolve-PodDns -Namespace 'app' -Deploy 'bff-a' -Fqdn $blobFqdn
  $code = Invoke-PodCurl -Namespace 'app' -Deploy 'bff-a' -Url $blobUrl -Insecure
  $t11 = Add-Result 'T11' 'app/bff-a' "$blobFqdn ($ip)" 'TLS 연결 성공(≠000)' $code (Get-TlsVerdict -ResolvedIp $ip -Code $code -Expect 'ok') "DNS=$ip"

  Write-Host '== 차단 테스트 =='
  $ctrl = @($t1, $t2c)
  $run = Invoke-VmCurl -Vm $Cfg.VmOther -Url $ingressUrl -HostHeader $ingressHost -Detailed
  $cn = Get-ControlNote $ctrl
  $null = Add-Result 'T2' "VM $($Cfg.VmOther)" "$($Cfg.IngressIp):80 Host $ingressHost" 'blocked(000)' $run.Code `
    (Get-HttpVerdict -Code $run.Code -Expect 'blocked' -ControlPassed ($cn -eq '' -and $run.Ran)) (Join-Note @($cn, (Get-RunNote $run)))

  # T3: T1 재사용 전에 nsg-ingress Deny 규칙과 snet-ingress 연결을 읽기 전용으로 확인한다
  $rg = $Cfg.ResourceGroup; $nsg = $Cfg.NsgIngress; $rule = $Cfg.NsgIngressDenyRule
  try {
    $access = ''
    if (Test-AzResource @('network', 'nsg', 'rule', 'show', '-g', $rg, '--nsg-name', $nsg, '-n', $rule, '--query', 'id')) {
      $access = [string](Invoke-Az @('network', 'nsg', 'rule', 'show', '-g', $rg, '--nsg-name', $nsg, '-n', $rule, '--query', 'access', '-o', 'tsv'))
    }
    $subnetNsgId = [string](Invoke-Az @('network', 'vnet', 'subnet', 'show', '-g', $rg, '--vnet-name', $Cfg.Vnet, '-n', $Cfg.Subnets.ingress.Name, '--query', 'networkSecurityGroup.id', '-o', 'tsv'))
    $t3 = Get-NsgReuseVerdict -T1Verdict $t1.Verdict -RuleAccess $access -SubnetNsgId $subnetNsgId -NsgName $nsg -RuleName $rule
  } catch {
    $t3 = [pscustomobject]@{ Verdict = 'INCONCLUSIVE'; Note = "NSG 확인 실패: $($_.Exception.Message)" }
  }
  $null = Add-Result 'T3' "VM $($Cfg.VmAppgw)" "$($Cfg.IngressIp):80 (T1 재사용)" '200' $t1.Observed $t3.Verdict $t3.Note

  $code = Invoke-PodCurl -Namespace 'web' -Deploy 'web-a' -Url $bffB
  $cn = Get-ControlNote @($t6)
  $null = Add-Result 'T5' 'web/web-a' 'bff-b:8080' '403' $code (Get-HttpVerdict -Code $code -Expect '403' -ControlPassed ($cn -eq '')) $cn

  $code = Invoke-PodCurl -Namespace 'web' -Deploy 'web-b' -Url $bffA
  $cn = Get-ControlNote @($t4)
  $null = Add-Result 'T7' 'web/web-b' 'bff-a:8080' '403' $code (Get-HttpVerdict -Code $code -Expect '403' -ControlPassed ($cn -eq '')) $cn

  # probe 쪽 exec 경로는 대조군(T4, web-a 출발)으로 검증되지 않으므로 curl 실제 실행 여부도 함께 게이트한다
  $run = Invoke-PodCurl -Namespace 'nomesh' -Deploy 'probe' -Url $bffA -Detailed
  $cn = Get-ControlNote @($t4)
  $t8Passed = $cn -eq '' -and $run.Ran
  $extra = if ($run.Code -notin '000', '200') { "연결은 되었으나 코드 $($run.Code) (200 아님)" } else { '' }
  $null = Add-Result 'T8' 'nomesh/probe' 'bff-a:8080' 'blocked(000)' $run.Code `
    (Get-HttpVerdict -Code $run.Code -Expect 'blocked' -ControlPassed $t8Passed) (Join-Note @($cn, (Get-RunNote $run), $extra))

  $code = Invoke-PodCurl -Namespace 'web' -Deploy 'web-a' -Url $webB
  $cn = Get-ControlNote @($t1)
  $null = Add-Result 'T9' 'web/web-a' 'web-b:8080 (Ingress 우회)' '403' $code (Get-HttpVerdict -Code $code -Expect '403' -ControlPassed ($cn -eq '')) $cn

  $ip = Resolve-PodDns -Namespace 'web' -Deploy 'web-a' -Fqdn $blobFqdn
  $run = Invoke-PodCurl -Namespace 'web' -Deploy 'web-a' -Url $blobUrl -Insecure -Detailed
  $cn = Get-ControlNote @($t11)
  $null = Add-Result 'T10' 'web/web-a' "$blobFqdn ($ip)" 'TLS 연결 실패(000)' $run.Code `
    (Get-TlsVerdict -ResolvedIp $ip -Code $run.Code -Expect 'fail' -ControlPassed ($cn -eq '' -and $run.Ran)) (Join-Note @("DNS=$ip", $cn, (Get-RunNote $run)))
}

function Invoke-ProbeTest {
  # T14: STRICT mTLS 에서도 readinessProbe 가 Istio rewrite(15020 /app-health/)로 통과해 Ready 인지
  $id = 'T14'; $to = 'web-a/web-b/bff-a/bff-b readinessProbe'; $expect = 'Ready + 15020 /app-health/ rewrite'
  Write-Host '== readinessProbe rewrite (T14) =='
  try {
    $items = foreach ($t in @(@('web', 'web-a'), @('web', 'web-b'), @('app', 'bff-a'), @('app', 'bff-b'))) {
      $ns, $name = $t
      $pods = @((Invoke-Kube @('get', 'pods', '-n', $ns, '-l', "app=$name", '-o', 'json') -Json).items |
          Where-Object { -not $_.metadata.PSObject.Properties['deletionTimestamp'] })
      foreach ($p in $pods) {
        $c = @($p.spec.containers | Where-Object { $_.name -eq 'app' })[0]
        $port = $null; $path = $null
        $rp = $c.PSObject.Properties['readinessProbe']
        if ($rp -and $rp.Value.PSObject.Properties['httpGet']) { $port = [string]$rp.Value.httpGet.port; $path = [string]$rp.Value.httpGet.path }
        $conds = if ($p.status.PSObject.Properties['conditions']) { @($p.status.conditions) } else { @() }
        $ready = @($conds | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0
        [pscustomobject]@{ Name = "$ns/$($p.metadata.name)"; Ready = $ready; Port = $port; Path = $path }
      }
    }
    $v = Get-ProbeRewriteVerdict -Pods @($items)
    $null = Add-Result $id 'kubelet' $to $expect $v.Observed $v.Verdict $v.Reason
  } catch {
    $null = Add-Result $id 'kubelet' $to $expect '오류' 'INCONCLUSIVE' "실행 오류: $($_.Exception.Message)"
  }
}

function Invoke-Kube {
  # 전용 kubeconfig로 kubectl 실행. 실패하면 stderr와 함께 throw, -Json 이면 객체로 변환
  param([Parameter(Mandatory)][string[]]$Arguments, [switch]$Json)
  $stdout = [System.Collections.Generic.List[string]]::new()
  $stderr = [System.Collections.Generic.List[string]]::new()
  & kubectl --kubeconfig $Kubeconfig @Arguments 2>&1 | ForEach-Object {
    if ($_ -is [System.Management.Automation.ErrorRecord]) { $stderr.Add($_.ToString()) } else { $stdout.Add([string]$_) }
  }
  if ($LASTEXITCODE -ne 0) { throw "kubectl $($Arguments[0..1] -join ' ') 실패(종료 코드 $LASTEXITCODE): $(($stderr -join ' ').Trim())" }
  $text = ($stdout -join "`n")
  if ($Json) { return ($text | ConvertFrom-Json -Depth 100) }
  return $text.Trim()
}

function Wait-Until {
  # 조건 스크립트가 참이 될 때까지 대기. 시간 초과면 $false
  param([scriptblock]$Condition, [int]$TimeoutSec, [int]$IntervalSec)
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ($true) {
    if (& $Condition) { return $true }
    if ((Get-Date) -ge $deadline) { return $false }
    Start-Sleep -Seconds $IntervalSec
  }
}

function Set-HpaMin {
  param([int]$Min)
  $null = Invoke-Kube @('patch', 'hpa', 'hpa-demo', '-n', 'scale', '--type', 'merge', '-p', "{`"spec`":{`"minReplicas`":$Min}}")
}

function Invoke-HpaTest {
  $id = 'T12'; $to = 'scale/hpa-demo (minReplicas 5→2)'; $expect = '5→4→3→2, 간격 ≥55초'
  Write-Host '== HPA 축소 (T12) =='
  try {
    # 이전 실행이 중간에 끊겼을 수 있으므로 시작 상태를 minReplicas 5로 맞춘 뒤 5개 Ready 확인
    Set-HpaMin -Min 5
    $ready = Wait-Until -TimeoutSec 300 -IntervalSec 5 -Condition {
      $d = Invoke-Kube @('get', 'deploy', 'hpa-demo', '-n', 'scale', '-o', 'json') -Json
      $r = if ($d.status.PSObject.Properties['readyReplicas']) { [int]$d.status.readyReplicas } else { 0 }
      [int]$d.spec.replicas -eq 5 -and $r -eq 5
    }
    if (-not $ready) {
      $null = Add-Result $id '—' $to $expect '5개 Ready 아님' 'INCONCLUSIVE' '시작 조건(hpa-demo 5개 Ready) 미충족, 5분 대기 초과'
      return
    }

    $zBefore = Get-PodZoneCounts -Namespace 'scale' -Selector 'app=hpa-demo'
    Write-Host "축소 전 hpa-demo Pod 영역 분포: $(Format-ZoneShort $zBefore.Counts)"
    $samples = [System.Collections.Generic.List[object]]::new()
    $getReplicas = { [int](Invoke-Kube @('get', 'deploy', 'hpa-demo', '-n', 'scale', '-o', 'jsonpath={.spec.replicas}')) }
    $samples.Add([pscustomobject]@{ Time = Get-Date; Replicas = (& $getReplicas) })
    Set-HpaMin -Min 2
    $patchTime = Get-Date
    Write-Host "minReplicas 2 패치: $($patchTime.ToString('HH:mm:ss'))"
    $deadline = $patchTime.AddMinutes(15)
    $last = $samples[0].Replicas
    while ((Get-Date) -lt $deadline) {
      Start-Sleep -Seconds 5
      $rep = & $getReplicas
      $now = Get-Date
      $samples.Add([pscustomobject]@{ Time = $now; Replicas = $rep })
      if ($rep -ne $last) { Write-Host ("  {0} replicas {1}→{2}" -f $now.ToString('HH:mm:ss'), $last, $rep); $last = $rep }
      if ($rep -le 2) { break }
    }

    $hv = Get-HpaVerdict -Samples $samples.ToArray()
    $firstDrop = $samples | Where-Object { $_.Replicas -ne $samples[0].Replicas } | Select-Object -First 1
    $firstNote = if ($firstDrop) { "패치→첫 감소 $([int]($firstDrop.Time - $patchTime).TotalSeconds)초(판정 외)" } else { '감소 없음' }
    $observed = "$($hv.Sequence -join ',') (간격 $((@($hv.IntervalsSec) | ForEach-Object { [int]$_ }) -join ',')초)"
    $null = Add-Result $id '—' $to $expect $observed $hv.Verdict (Join-Note @($hv.Reason, $firstNote, "표본 $($samples.Count)개/5초"))

    # T12b: 분산 제약(DoNotSchedule)은 배치 때만 적용된다. 축소 후 영역 분포를 기록만 한다(판정 없음)
    $null = Wait-Until -TimeoutSec 90 -IntervalSec 5 -Condition { (Get-PodZoneCounts -Namespace 'scale' -Selector 'app=hpa-demo').Running -le 2 }
    $zAfter = Get-PodZoneCounts -Namespace 'scale' -Selector 'app=hpa-demo'
    $vals = @('1', '2', '3' | ForEach-Object { if ($zAfter.Counts.ContainsKey($_)) { $zAfter.Counts[$_] } else { 0 } })
    $diff = ($vals | Measure-Object -Maximum).Maximum - ($vals | Measure-Object -Minimum).Minimum
    $null = Add-Result 'T12b' '—' 'scale/hpa-demo 영역 분포(DoNotSchedule, minDomains 3)' '기록(판정 없음)' `
      "축소 전 $(Format-ZoneShort $zBefore.Counts) → 축소 후 $(Format-ZoneShort $zAfter.Counts)" 'INFO' `
      "축소 후 영역별 Pod 수 차이 $diff (Running $($zAfter.Running)); Pod 2개·영역 3개라 빈 영역 1개는 필연. 영역 하한은 T12c(minReplicas 3)에서 판정"
  } catch {
    $null = Add-Result $id '—' $to $expect '오류' 'INCONCLUSIVE' "실행 오류: $($_.Exception.Message)"
  } finally {
    try { Set-HpaMin -Min 5; Write-Host 'hpa-demo minReplicas 5 원복' }
    catch { Write-Warning "hpa-demo minReplicas 원복 실패: $($_.Exception.Message)" }
  }
}

function Invoke-ZoneFloorTest {
  # T12c: 분산 제약은 축소 때 적용되지 않는다. minReplicas 3(=영역 수)으로 축소해도 세 영역에 1개씩 남는지 3회 반복 확인
  $id = 'T12c'; $to = 'scale/hpa-demo (minReplicas 5→3, 3회 반복)'; $expect = '매회 세 영역 모두 Pod ≥1'
  Write-Host '== 축소 뒤 영역 하한 (T12c) =='
  $rounds = [System.Collections.Generic.List[hashtable]]::new()
  $log = [System.Collections.Generic.List[string]]::new()
  try {
    foreach ($n in 1..3) {
      Set-HpaMin -Min 5
      $ok = Wait-Until -TimeoutSec 300 -IntervalSec 5 -Condition {
        $z = Get-PodZoneCounts -Namespace 'scale' -Selector 'app=hpa-demo'
        $z.Running -eq 5 -and $z.Pending -eq 0
      }
      if (-not $ok) {
        $null = Add-Result $id '—' $to $expect "${n}회 시작 조건 미충족" 'INCONCLUSIVE' "hpa-demo 5개 Running 아님, 5분 대기 초과; $($log -join ', ')"
        return
      }
      $zBefore = Get-PodZoneCounts -Namespace 'scale' -Selector 'app=hpa-demo'
      Set-HpaMin -Min 3
      $null = Wait-Until -TimeoutSec 600 -IntervalSec 5 -Condition {
        $r = [int](Invoke-Kube @('get', 'deploy', 'hpa-demo', '-n', 'scale', '-o', 'jsonpath={.spec.replicas}'))
        $r -eq 3 -and (Get-PodZoneCounts -Namespace 'scale' -Selector 'app=hpa-demo').Running -eq 3
      }
      $zAfter = Get-PodZoneCounts -Namespace 'scale' -Selector 'app=hpa-demo'
      $line = "${n}회 $(Format-ZoneShort $zBefore.Counts)→$(Format-ZoneShort $zAfter.Counts)"
      Write-Host "  $line"
      $log.Add($line); $rounds.Add($zAfter.Counts)
    }
    $fv = Get-ZoneFloorVerdict -Rounds $rounds.ToArray() -Expected 3
    $null = Add-Result $id '—' $to $expect ($log -join ', ') $fv.Verdict $fv.Reason
  } catch {
    $null = Add-Result $id '—' $to $expect '오류' 'INCONCLUSIVE' "실행 오류: $($_.Exception.Message)"
  } finally {
    try { Set-HpaMin -Min 5; Write-Host 'hpa-demo minReplicas 5 원복' }
    catch { Write-Warning "hpa-demo minReplicas 원복 실패: $($_.Exception.Message)" }
  }
}

function Get-UserNodeZones {
  $nodes = Invoke-Kube @('get', 'nodes', '-l', 'kubernetes.azure.com/mode=user', '-L', 'topology.kubernetes.io/zone', '--no-headers')
  # 마지막 열이 영역 레이블
  return @($nodes -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { ($_.Trim() -split '\s+')[-1] })
}

function Format-ZoneCounts {
  param([hashtable]$Counts)
  ('1', '2', '3' | ForEach-Object { $n = if ($Counts.ContainsKey($_)) { $Counts[$_] } else { 0 }; "영역$_=$n" }) -join ', '
}

function Format-ZoneShort {
  param([hashtable]$Counts)
  ('1', '2', '3' | ForEach-Object { if ($Counts.ContainsKey($_)) { $Counts[$_] } else { 0 } }) -join '/'
}

function Get-PodZoneCounts {
  # 선택한 Pod 의 영역별 Running 수와 Pending 수(삭제 중 Pod 제외)
  param([string]$Namespace, [string]$Selector)
  $zoneOf = @{}
  foreach ($n in @((Invoke-Kube @('get', 'nodes', '-o', 'json') -Json).items)) {
    $l = $n.metadata.labels.PSObject.Properties['topology.kubernetes.io/zone']
    $zoneOf[$n.metadata.name] = if ($l) { ConvertTo-ZoneKey -Zone $l.Value } else { '' }
  }
  $pods = @((Invoke-Kube @('get', 'pods', '-n', $Namespace, '-l', $Selector, '-o', 'json') -Json).items |
      Where-Object { -not $_.metadata.PSObject.Properties['deletionTimestamp'] })
  $h = @{}; $running = 0; $pending = 0
  $names = [System.Collections.Generic.List[string]]::new()
  foreach ($p in $pods) {
    $names.Add($p.metadata.name)
    if ($p.status.phase -eq 'Pending') { $pending++; continue }
    if ($p.status.phase -ne 'Running') { continue }
    $running++
    $node = $p.spec.PSObject.Properties['nodeName']
    $z = if ($node -and $zoneOf.ContainsKey($node.Value)) { $zoneOf[$node.Value] } else { '' }
    if ($z) { if ($h.ContainsKey($z)) { $h[$z]++ } else { $h[$z] = 1 } }
  }
  [pscustomobject]@{ Counts = $h; Running = $running; Pending = $pending; Names = $names.ToArray() }
}

function Wait-UserNodesMin {
  # 이전 확장의 노드가 남아 있으면 새 Pod 가 기존 노드에 들어가 CAS 확장을 검증하지 못하므로 풀마다 최소 대수가 될 때까지 대기
  param([int]$TimeoutSec = 1500)
  $isMin = {
    $c = Get-ZoneNodeCounts -Zones (Get-UserNodeZones)
    @('1', '2', '3' | Where-Object { -not $c.ContainsKey($_) -or $c[$_] -ne $Cfg.UserMin }).Count -eq 0
  }
  if (& $isMin) { return $true }
  Write-Host "사용자 노드가 최소($($Cfg.UserMin)대/풀) 상태가 아님: CAS 축소 대기(최대 $([int]($TimeoutSec / 60))분)"
  return (Wait-Until -TimeoutSec $TimeoutSec -IntervalSec 30 -Condition $isMin)
}

function Get-ScaleEventNote {
  # 보조 근거(판정 외): 지정 Pod 의 TriggeredScaleUp 이벤트, Pending 이면 스케줄 실패 사유. 조회 실패는 판정을 바꾸지 않는다
  param([System.Collections.Generic.HashSet[string]]$PodNames, [int]$Pending)
  try {
    $events = @((Invoke-Kube @('get', 'events', '-n', 'scale', '-o', 'json') -Json).items |
        Where-Object { $_.involvedObject.kind -eq 'Pod' -and $PodNames.Contains($_.involvedObject.name) })
    $scaleUps = @($events | Where-Object { $_.reason -eq 'TriggeredScaleUp' } | ForEach-Object { $_.message } | Select-Object -Unique)
    $scaleNote = if ($scaleUps.Count) { 'TriggeredScaleUp: ' + ($scaleUps -join ' / ') } else { 'TriggeredScaleUp 이벤트 없음' }
    $causeNote = ''
    if ($Pending -gt 0) {
      $causes = @($events | Where-Object { $_.reason -in 'FailedScheduling', 'NotTriggerScaleUp', 'FailedScaleUp' } |
          ForEach-Object { "$($_.reason): $($_.message)" } | Select-Object -Unique -Last 3)
      $causeNote = 'Pending 사유: ' + $(if ($causes.Count) { $causes -join ' / ' } else { '이벤트 없음' })
    }
    return (Join-Note @($causeNote, $scaleNote))
  } catch {
    return "이벤트 조회 실패: $($_.Exception.Message)"
  }
}

function Invoke-ZoneTest {
  $id = 'T13'; $to = "사용자 노드 풀 $($Cfg.UserPools -join '/')"; $expect = '확장 후 영역별 노드 수 차이 ≤1'
  $target = 6
  Write-Host '== 영역 균형 (T13) =='
  try {
    $aks = Invoke-Az @('aks', 'show', '-g', $Cfg.ResourceGroup, '-n', $Cfg.Aks, '-o', 'json')
    $balance = [string]$aks.autoScalerProfile.balanceSimilarNodeGroups
    $poolZones = foreach ($p in $Cfg.UserPools) {
      $prof = @($aks.agentPoolProfiles | Where-Object { $_.name -eq $p }) | Select-Object -First 1
      $z = if ($prof -and $prof.availabilityZones) { @($prof.availabilityZones) -join '+' } else { '없음' }
      "$p=$z"
    }
    $zonesOk = ($poolZones -join ',') -eq (@(0..2 | ForEach-Object { "$($Cfg.UserPools[$_])=$($_ + 1)" }) -join ',')
    $setting = "balanceSimilarNodeGroups=$balance; $($poolZones -join ', ')"
    Write-Host "설정 확인: $setting"
    if ($balance -ne 'true' -or -not $zonesOk) {
      $null = Add-Result $id '—' $to $expect '설정 불일치' 'INCONCLUSIVE' "대조군(설정 확인) 실패: $setting"
      return
    }

    if (-not (Wait-UserNodesMin)) {
      $now = Get-ZoneNodeCounts -Zones (Get-UserNodeZones)
      $null = Add-Result $id '—' $to $expect (Format-ZoneCounts $now) 'INCONCLUSIVE' "시작 조건 미충족: 사용자 노드가 풀당 $($Cfg.UserMin)대로 돌아오지 않음(25분 대기)"
      return
    }
    $before = Get-ZoneNodeCounts -Zones (Get-UserNodeZones)
    Write-Host "확장 전 사용자 노드: $(Format-ZoneCounts $before)"
    $start = Get-Date
    $null = Invoke-Kube @('scale', 'deploy', 'zone-fill', '-n', 'scale', "--replicas=$target")
    $podNames = [System.Collections.Generic.HashSet[string]]::new()
    $running = 0
    $deadline = $start.AddMinutes(15)
    while ($true) {
      $pods = @((Invoke-Kube @('get', 'pods', '-n', 'scale', '-l', 'app=zone-fill', '-o', 'json') -Json).items)
      foreach ($p in $pods) { $null = $podNames.Add($p.metadata.name) }
      $running = @($pods | Where-Object { $_.status.phase -eq 'Running' -and -not $_.metadata.PSObject.Properties['deletionTimestamp'] }).Count
      Write-Host ("  {0} zone-fill Running {1}/{2}, 사용자 노드 {3}" -f (Get-Date).ToString('HH:mm:ss'), $running, $target, (Format-ZoneCounts (Get-ZoneNodeCounts -Zones (Get-UserNodeZones))))
      if ($running -ge $target -or (Get-Date) -ge $deadline) { break }
      Start-Sleep -Seconds 15
    }
    $elapsed = [int]((Get-Date) - $start).TotalSeconds
    $pending = [Math]::Max(0, $target - $running)

    $after = Get-ZoneNodeCounts -Zones (Get-UserNodeZones)
    $beforeTotal = ($before.Values | Measure-Object -Sum).Sum
    $zv = Get-ZoneBalanceVerdict -NodesByZone $after -PendingCount $pending -NodesBefore $beforeTotal

    $eventNote = Get-ScaleEventNote -PodNames $podNames -Pending $pending
    $capNote = ''
    if (@('1', '2', '3' | Where-Object { $after.ContainsKey($_) -and $after[$_] -ge $Cfg.UserMax }).Count -eq 3) {
      $capNote = "모든 풀이 최대($($Cfg.UserMax)대)에 도달: 균형이 최대값 제한으로 강제되었을 수 있음"
    }
    $note = Join-Note @($zv.Reason, "확장 전 $(Format-ZoneCounts $before)", "Running $running/$target, ${elapsed}초", $capNote, $eventNote, "설정: $setting")
    $null = Add-Result $id '—' $to $expect (Format-ZoneCounts $after) $zv.Verdict $note
  } catch {
    $null = Add-Result $id '—' $to $expect '오류' 'INCONCLUSIVE' "실행 오류: $($_.Exception.Message)"
  } finally {
    try { $null = Invoke-Kube @('scale', 'deploy', 'zone-fill', '-n', 'scale', '--replicas=0'); Write-Host 'zone-fill 0으로 원복(CAS 축소는 10분 이상 걸리며 판정하지 않음)' }
    catch { Write-Warning "zone-fill 원복 실패: $($_.Exception.Message)" }
  }
}

function Invoke-SpreadTest {
  # T13b: PRD 제안 YAML 의 영역 강제 분산(DoNotSchedule + minDomains 3)이 CAS 확장과 함께 Pod 2/2/2 를 만드는지
  $id = 'T13b'; $to = 'scale/zone-spread 6개(DoNotSchedule, minDomains 3)'; $expect = 'Pod 2/2/2, Pending 없음'
  $target = 6
  Write-Host '== 영역 강제 분산 + CAS (T13b) =='
  try {
    if (-not (Wait-UserNodesMin)) {
      $now = Get-ZoneNodeCounts -Zones (Get-UserNodeZones)
      $null = Add-Result $id '—' $to $expect "노드 $(Format-ZoneShort $now)" 'INCONCLUSIVE' "시작 조건 미충족: 사용자 노드가 풀당 $($Cfg.UserMin)대로 돌아오지 않음(25분 대기)"
      return
    }
    $before = Get-ZoneNodeCounts -Zones (Get-UserNodeZones)
    Write-Host "확장 전 사용자 노드: $(Format-ZoneCounts $before)"
    $start = Get-Date
    $null = Invoke-Kube @('scale', 'deploy', 'zone-spread', '-n', 'scale', "--replicas=$target")
    $podNames = [System.Collections.Generic.HashSet[string]]::new()
    $deadline = $start.AddMinutes(15)
    while ($true) {
      Start-Sleep -Seconds 15
      $pc = Get-PodZoneCounts -Namespace 'scale' -Selector 'app=zone-spread'
      foreach ($n in $pc.Names) { $null = $podNames.Add($n) }
      Write-Host ("  {0} zone-spread Running {1}/{2} (Pod {3}, Pending {4}), 사용자 노드 {5}" -f (Get-Date).ToString('HH:mm:ss'), $pc.Running, $target,
        (Format-ZoneShort $pc.Counts), $pc.Pending, (Format-ZoneShort (Get-ZoneNodeCounts -Zones (Get-UserNodeZones))))
      if ($pc.Running -ge $target -or (Get-Date) -ge $deadline) { break }
    }
    $elapsed = [int]((Get-Date) - $start).TotalSeconds
    $after = Get-ZoneNodeCounts -Zones (Get-UserNodeZones)
    $sv = Get-PodSpreadVerdict -PodsByZone $pc.Counts -PendingCount $pc.Pending -Expected $target
    $eventNote = Get-ScaleEventNote -PodNames $podNames -Pending $pc.Pending
    $observed = "Pod $(Format-ZoneShort $pc.Counts), 노드 $(Format-ZoneShort $before)→$(Format-ZoneShort $after)"
    $null = Add-Result $id '—' $to $expect $observed $sv.Verdict (Join-Note @($sv.Reason, "Running $($pc.Running)/$target, ${elapsed}초", $eventNote))
  } catch {
    $null = Add-Result $id '—' $to $expect '오류' 'INCONCLUSIVE' "실행 오류: $($_.Exception.Message)"
  } finally {
    try { $null = Invoke-Kube @('scale', 'deploy', 'zone-spread', '-n', 'scale', '--replicas=0'); Write-Host 'zone-spread 0으로 원복' }
    catch { Write-Warning "zone-spread 원복 실패: $($_.Exception.Message)" }
  }
}

if ($Only -in 'All', 'Network') { Invoke-NetworkTests; Invoke-ProbeTest }
if ($Only -in 'All', 'Hpa') { Invoke-HpaTest }
if ($Only -in 'All', 'Floor') { Invoke-ZoneFloorTest }
if ($Only -in 'All', 'Zone') { Invoke-ZoneTest }
if ($Only -in 'All', 'Spread') { Invoke-SpreadTest }

$order = 'T1', 'T2', 'T2c', 'T3', 'T4', 'T5', 'T6', 'T7', 'T8', 'T9', 'T10', 'T11', 'T12', 'T12b', 'T12c', 'T13', 'T13b', 'T14'
$sorted = @($Results | Sort-Object { [array]::IndexOf($order, $_.Id) })
$null = Save-Results -Results $sorted
