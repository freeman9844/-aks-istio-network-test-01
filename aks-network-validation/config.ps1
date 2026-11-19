# 공통 설정. 모든 스크립트는 이 파일을 dot-source 해서 $Cfg로만 이름·주소를 참조한다.
# 리소스 그룹은 dot-source 전에 $ResourceGroup 변수를 정해 두면 그 값을 쓴다.

if (-not (Get-Variable -Name ResourceGroup -ValueOnly -ErrorAction SilentlyContinue)) {
  $ResourceGroup = 'rg-aksnetval-krc'
}

# 구독 ID는 Storage 이름 해시에만 쓰고 파일에 남기지 않는다
$subscriptionId = (az account show --query id -o tsv 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($subscriptionId)) {
  throw 'az account show 실패: az login 후 다시 실행하세요'
}
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
  $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$($subscriptionId.Trim())/$ResourceGroup"))
} finally {
  $sha.Dispose()
}
$storageSuffix = (-join ($hashBytes | ForEach-Object { $_.ToString('x2') })).Substring(0, 6)
Remove-Variable -Name subscriptionId, sha, hashBytes -ErrorAction SilentlyContinue

$Cfg = @{
  ResourceGroup = $ResourceGroup
  Location      = 'koreacentral'
  Vnet          = 'vnet-aksnetval'
  VnetPrefix    = '10.50.0.0/16'
  Subnets       = @{
    aksApp   = @{ Name = 'snet-aks-app'; Prefix = '10.50.4.0/22' }
    ingress  = @{ Name = 'snet-ingress'; Prefix = '10.50.1.0/27' }
    pe       = @{ Name = 'snet-pe'; Prefix = '10.50.2.0/24' }
    appgwSim = @{ Name = 'snet-appgw-sim'; Prefix = '10.50.3.0/27' }
    other    = @{ Name = 'snet-other'; Prefix = '10.50.3.32/27' }
  }
  NsgAksApp     = 'nsg-aks-app'
  NsgIngress    = 'nsg-ingress'
  # nsg-ingress 의 Deny 규칙(01-infra 생성, 03-verify T3 확인)
  NsgIngressDenyRule = 'deny-appgw-all'
  Identity      = 'id-aksnetval'
  IngressIp     = '10.50.1.10'
  PodCidr       = '192.168.0.0/16'
  Aks           = 'aks-aksnetval'
  SystemVmSize  = 'Standard_D4s_v5'
  UserVmSize    = 'Standard_D2s_v5'
  UserPools     = @('userz1', 'userz2', 'userz3')
  UserMin       = 1
  UserMax       = 3
  # koreacentral 에는 Standard_B2s 가 제공되지 않아(list-skus 에 없음, 용량 제한) v2 로 대체
  VmSize        = 'Standard_B2s_v2'
  VmAppgw       = 'vm-appgw-sim'
  VmOther       = 'vm-other'
  Storage       = "staksnetval$storageSuffix".ToLowerInvariant()
  BlobPe        = 'pe-blob-aksnetval'
  BlobDnsZone   = 'privatelink.blob.core.windows.net'
  BlobDnsLink   = 'link-vnet-aksnetval'
  Tags          = @('purpose=aksnetval')
  ResultsDir    = Join-Path $PSScriptRoot 'results'
}
Remove-Variable -Name storageSuffix -ErrorAction SilentlyContinue
