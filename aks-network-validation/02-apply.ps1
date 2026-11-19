#Requires -Version 7
# 매니페스트 적용. 전용 kubeconfig(results/.kubeconfig)만 쓰고 현재 kubectl 컨텍스트는 바꾸지 않는다.
# 사용: ./02-apply.ps1 [-ResourceGroup <이름>]
[CmdletBinding()]
param(
  [string]$ResourceGroup
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'config.ps1')
Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/Verdict.psm1') -Force

$GatewayNs = 'aks-istio-ingress'
$GatewaySvc = 'aks-istio-ingressgateway-internal'
$GatewayLabel = 'istio=aks-istio-ingressgateway-internal'
$ManifestDir = Join-Path $PSScriptRoot 'manifests'
$WorkloadNs = @('web', 'app', 'nomesh', 'scale')

# az aks install-cli 기본 설치 위치
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
  $cliDir = Join-Path $env:USERPROFILE '.azure-kubectl'
  if (Test-Path (Join-Path $cliDir 'kubectl.exe')) { $env:Path = "$cliDir;$env:Path" }
  else { throw 'kubectl 을 찾을 수 없습니다: az aks install-cli 로 설치하세요' }
}

function Invoke-Kubectl {
  # 항상 전용 kubeconfig 로 실행하고 실패하면 stderr 와 함께 throw
  param([Parameter(Mandatory, Position = 0)][string[]]$Arguments)
  $stdout = [System.Collections.Generic.List[string]]::new()
  $stderr = [System.Collections.Generic.List[string]]::new()
  & kubectl --kubeconfig $script:Kubeconfig @Arguments 2>&1 | ForEach-Object {
    if ($_ -is [System.Management.Automation.ErrorRecord]) { $stderr.Add($_.ToString()) }
    else { $stdout.Add([string]$_) }
  }
  if ($LASTEXITCODE -ne 0) {
    throw ("kubectl {0} 실패(종료 코드 {1}): {2}" -f (($Arguments | Select-Object -First 3) -join ' '), $LASTEXITCODE, ($stderr -join "`n").Trim())
  }
  return ($stdout -join "`n").Trim()
}

function Wait-Until {
  # 조건 스크립트 블록이 참(비어 있지 않은 값)을 돌려줄 때까지 기다린다
  param(
    [Parameter(Mandatory)][string]$Label,
    [Parameter(Mandatory)][scriptblock]$Condition,
    [int]$TimeoutSec = 600,
    [int]$IntervalSec = 10
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ($true) {
    $value = $null
    try { $value = & $Condition } catch { $value = $null }
    if ($value) { return $value }
    if ((Get-Date) -gt $deadline) { throw "시간 초과($TimeoutSec 초): $Label" }
    Write-Host "대기 중: $Label"
    Start-Sleep -Seconds $IntervalSec
  }
}

function Invoke-ManifestApply {
  param([Parameter(Mandatory)][string]$Name)
  Write-Host "적용: $Name"
  Write-Host (Invoke-Kubectl @('apply', '-f', (Join-Path $ManifestDir $Name)))
}

try {
  $script:Kubeconfig = Get-AksKubeconfig $Cfg
  Write-Host "전용 kubeconfig: $script:Kubeconfig"

  # 1) 내부 Ingress Gateway
  $gateways = Invoke-Az @('aks', 'show', '-g', $Cfg.ResourceGroup, '-n', $Cfg.Aks, '--query', 'serviceMeshProfile.istio.components.ingressGateways', '-o', 'json')
  $internalOn = @($gateways | Where-Object { $_ -and $_.mode -eq 'Internal' -and $_.enabled }).Count -gt 0
  if ($internalOn) {
    Write-Host '이미 있음: 내부 Ingress Gateway'
  } else {
    Write-Host '생성: 내부 Ingress Gateway (수 분 걸림)'
    $null = Invoke-Az @('aks', 'mesh', 'enable-ingress-gateway', '-g', $Cfg.ResourceGroup, '-n', $Cfg.Aks, '--ingress-gateway-type', 'internal')
  }

  # 2) Gateway Service 어노테이션: snet-ingress 의 고정 IP 로 ILB 를 만든다
  $null = Wait-Until -Label "Service $GatewayNs/$GatewaySvc" -Condition {
    Invoke-Kubectl @('get', 'svc', '-n', $GatewayNs, $GatewaySvc, '-o', 'name')
  }
  $subnet = $Cfg.Subnets.ingress.Name
  Assert-NotEmpty -Value $subnet -Name 'Ingress 서브넷 이름'
  Assert-NotEmpty -Value $Cfg.IngressIp -Name 'Ingress IP'
  $null = Invoke-Kubectl @('annotate', 'svc', '-n', $GatewayNs, $GatewaySvc, '--overwrite',
    "service.beta.kubernetes.io/azure-load-balancer-internal-subnet=$subnet",
    "service.beta.kubernetes.io/azure-load-balancer-ipv4=$($Cfg.IngressIp)")
  Write-Host "어노테이션 적용: subnet=$subnet, ipv4=$($Cfg.IngressIp)"

  # 3) 네임스페이스 + 사이드카 주입 레이블
  $rev = Invoke-Az @('aks', 'show', '-g', $Cfg.ResourceGroup, '-n', $Cfg.Aks, '--query', 'serviceMeshProfile.istio.revisions[0]', '-o', 'tsv')
  Assert-NotEmpty -Value $rev -Name 'Istio 리비전'
  Write-Host "Istio 리비전: $rev"
  Invoke-ManifestApply '00-namespaces.yaml'
  foreach ($ns in 'web', 'app') {
    $null = Invoke-Kubectl @('label', 'namespace', $ns, "istio.io/rev=$rev", '--overwrite')
  }

  # 4) Gateway Pod 의 SA 로 principal 을 만든다. 비어 있으면 모두 거부되므로 즉시 중단
  $sa = Wait-Until -Label "Gateway Pod($GatewayLabel)" -Condition {
    Invoke-Kubectl @('get', 'pod', '-n', $GatewayNs, '-l', $GatewayLabel, '-o', 'jsonpath={.items[0].spec.serviceAccountName}')
  } -TimeoutSec 300
  Assert-NotEmpty -Value $sa -Name 'Gateway ServiceAccount'
  $principal = "cluster.local/ns/$GatewayNs/sa/$sa"
  Write-Host "Gateway principal: $principal"

  # 5) 워크로드 → Istio 정책(치환) → NetworkPolicy → 확장 검증용
  Invoke-ManifestApply '10-web.yaml'
  Invoke-ManifestApply '11-app.yaml'
  Invoke-ManifestApply '12-nomesh.yaml'
  $rendered = (Get-Content -Raw (Join-Path $ManifestDir '20-istio.yaml')).Replace('__GATEWAY_PRINCIPAL__', $principal)
  if ($rendered -match '__GATEWAY_PRINCIPAL__') { throw '20-istio.yaml 치환 실패' }
  $renderedPath = Join-Path $Cfg.ResultsDir '20-istio.rendered.yaml'
  Set-Content -Path $renderedPath -Value $rendered -Encoding utf8NoBOM
  Write-Host '적용: 20-istio.yaml (principal 치환)'
  Write-Host (Invoke-Kubectl @('apply', '-f', $renderedPath))
  Invoke-ManifestApply '30-netpol.yaml'
  Invoke-ManifestApply '40-scale.yaml'

  # 6) 롤아웃 확인 (Gateway 포함)
  foreach ($ns in @($GatewayNs) + $WorkloadNs) {
    $deps = Invoke-Kubectl @('get', 'deployment', '-n', $ns, '-o', 'name')
    foreach ($d in ($deps -split "`n" | Where-Object { $_ })) {
      Write-Host "롤아웃 확인: $ns/$d"
      $null = Invoke-Kubectl @('rollout', 'status', '-n', $ns, $d, '--timeout', '5m')
    }
  }

  # 7) ILB IP 확인
  # 어노테이션 전에 동적 IP 를 받았을 수 있으므로 기대 IP 가 될 때까지 기다린다
  $ipPath = 'jsonpath={.status.loadBalancer.ingress[0].ip}'
  try {
    $ip = Wait-Until -Label "ILB IP $($Cfg.IngressIp)" -Condition {
      $cur = Invoke-Kubectl @('get', 'svc', '-n', $GatewayNs, $GatewaySvc, '-o', $ipPath)
      if ($cur -eq $Cfg.IngressIp) { $cur }
    } -TimeoutSec 600
  } catch {
    $cur = Invoke-Kubectl @('get', 'svc', '-n', $GatewayNs, $GatewaySvc, '-o', $ipPath)
    throw "Gateway ILB IP 가 '$cur' 입니다(기대 $($Cfg.IngressIp))"
  }
  Write-Host "Gateway ILB IP: $ip"
  Write-Host '적용 완료'
} catch {
  Write-Host "오류: $($_.Exception.Message)"
  exit 1
}
