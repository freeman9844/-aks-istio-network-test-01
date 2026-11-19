#Requires -Version 7
# 정리: 검증용 리소스 그룹을 삭제하고 전용 kubeconfig(results/.kubeconfig)를 지운다.
# 리소스 그룹 이름을 그대로 입력해야 삭제한다. -Force 를 명시하면 입력 확인을 건너뛴다(비대화형 실행용).
# 결과 파일(results/*.json, *.md, *.log)은 로컬에 그대로 둔다.
# 사용: ./04-cleanup.ps1 [-ResourceGroup <이름>] [-Force]
[CmdletBinding()]
param(
  [string]$ResourceGroup,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'config.ps1')
Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force

$rg = $Cfg.ResourceGroup
$kubeconfig = Join-Path $Cfg.ResultsDir '.kubeconfig'

try {
  $sub = Invoke-Az @('account', 'show', '--query', 'name', '-o', 'tsv')
  Write-Host "현재 구독: $sub"
  Write-Host "삭제 대상 리소스 그룹: $rg"

  $exists = (Invoke-Az @('group', 'exists', '-n', $rg)) -eq 'true'
  if (-not $exists) {
    Write-Host "리소스 그룹 $rg 이(가) 없습니다: 삭제할 Azure 리소스 없음"
  } else {
    if (-not $Force) {
      $answer = Read-Host "삭제하려면 리소스 그룹 이름을 그대로 입력하세요"
      if ($answer -cne $rg) {
        Write-Host '중단: 이름이 일치하지 않아 아무것도 삭제하지 않았습니다'
        exit 1
      }
    }
    $null = Invoke-Az @('group', 'delete', '-n', $rg, '--yes', '--no-wait')
    Write-Host "삭제 요청 완료(--no-wait). AKS 포함 삭제는 최대 약 1시간 걸릴 수 있음. 확인: az group exists -n $rg  → false 가 된 뒤에 01 을 다시 실행"
  }

  if (Test-Path $kubeconfig) {
    Remove-Item -LiteralPath $kubeconfig -Force
    Write-Host "삭제: $kubeconfig"
  }
} catch {
  Write-Error $_
  exit 1
}
