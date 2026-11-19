#Requires -Version 7
# 검증용 Azure 인프라 생성. 이미 있는 리소스는 건너뛰므로 다시 실행해도 안전하다.
# 사용: ./01-infra.ps1 [-ResourceGroup <이름>] [-Force]
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
$tags = @('--tags') + $Cfg.Tags

function Initialize-Resource {
  # show 로 확인하고 없을 때만 create 스크립트 블록을 실행한다
  param(
    [Parameter(Mandatory)][string]$Label,
    [Parameter(Mandatory)][string[]]$ShowArgs,
    [Parameter(Mandatory)][scriptblock]$Create
  )
  if (Test-AzResource $ShowArgs) {
    Write-Host "이미 있음: $Label"
    return $false
  }
  Write-Host "생성: $Label"
  $null = & $Create
  return $true
}

try {
  Confirm-Subscription -Force:$Force
  Test-Preflight $Cfg

  # 리소스 그룹
  $null = Initialize-Resource "리소스 그룹 $rg" @('group', 'show', '-n', $rg) {
    Invoke-Az (@('group', 'create', '-n', $rg, '-l', $Cfg.Location) + $tags)
  }

  # VNet·서브넷
  $null = Initialize-Resource "VNet $($Cfg.Vnet)" @('network', 'vnet', 'show', '-g', $rg, '-n', $Cfg.Vnet) {
    Invoke-Az (@('network', 'vnet', 'create', '-g', $rg, '-n', $Cfg.Vnet, '-l', $Cfg.Location, '--address-prefixes', $Cfg.VnetPrefix) + $tags)
  }
  foreach ($key in 'aksApp', 'ingress', 'pe', 'appgwSim', 'other') {
    $s = $Cfg.Subnets[$key]
    $null = Initialize-Resource "서브넷 $($s.Name)" @('network', 'vnet', 'subnet', 'show', '-g', $rg, '--vnet-name', $Cfg.Vnet, '-n', $s.Name) {
      Invoke-Az @('network', 'vnet', 'subnet', 'create', '-g', $rg, '--vnet-name', $Cfg.Vnet, '-n', $s.Name, '--address-prefixes', $s.Prefix)
    }
  }

  # NSG 2개와 규칙(설계 5.3), 서브넷 연결
  $appgwPrefix = $Cfg.Subnets.appgwSim.Prefix
  $otherPrefix = $Cfg.Subnets.other.Prefix
  $nsgPlan = @(
    @{ Nsg = $Cfg.NsgAksApp; Subnet = $Cfg.Subnets.aksApp.Name; Rules = @(
        @{ Name = 'allow-appgw-to-ingress'; Priority = 100; Access = 'Allow'; Src = $appgwPrefix; Dst = $Cfg.IngressIp; Proto = 'Tcp'; Port = '80' },
        @{ Name = 'deny-other-to-ingress'; Priority = 110; Access = 'Deny'; Src = $otherPrefix; Dst = $Cfg.IngressIp; Proto = 'Tcp'; Port = '80' }
      )
    },
    @{ Nsg = $Cfg.NsgIngress; Subnet = $Cfg.Subnets.ingress.Name; Rules = @(
        @{ Name = $Cfg.NsgIngressDenyRule; Priority = 100; Access = 'Deny'; Src = $appgwPrefix; Dst = '*'; Proto = '*'; Port = '*' }
      )
    }
  )
  foreach ($n in $nsgPlan) {
    $null = Initialize-Resource "NSG $($n.Nsg)" @('network', 'nsg', 'show', '-g', $rg, '-n', $n.Nsg) {
      Invoke-Az (@('network', 'nsg', 'create', '-g', $rg, '-n', $n.Nsg, '-l', $Cfg.Location) + $tags)
    }
    foreach ($r in $n.Rules) {
      $null = Initialize-Resource "NSG 규칙 $($n.Nsg)/$($r.Name)" @('network', 'nsg', 'rule', 'show', '-g', $rg, '--nsg-name', $n.Nsg, '-n', $r.Name) {
        Invoke-Az @('network', 'nsg', 'rule', 'create', '-g', $rg, '--nsg-name', $n.Nsg, '-n', $r.Name,
          '--priority', $r.Priority, '--direction', 'Inbound', '--access', $r.Access, '--protocol', $r.Proto,
          '--source-address-prefixes', $r.Src, '--source-port-ranges', '*',
          '--destination-address-prefixes', $r.Dst, '--destination-port-ranges', $r.Port)
      }
    }
    $attached = Invoke-Az @('network', 'vnet', 'subnet', 'show', '-g', $rg, '--vnet-name', $Cfg.Vnet, '-n', $n.Subnet, '--query', 'networkSecurityGroup.id', '-o', 'tsv')
    if ($attached -and ($attached -split '/')[-1] -eq $n.Nsg) {
      Write-Host "이미 있음: $($n.Subnet) ← $($n.Nsg) 연결"
    } else {
      Write-Host "생성: $($n.Subnet) ← $($n.Nsg) 연결"
      $null = Invoke-Az @('network', 'vnet', 'subnet', 'update', '-g', $rg, '--vnet-name', $Cfg.Vnet, '-n', $n.Subnet, '--network-security-group', $n.Nsg)
    }
  }

  # 사용자 할당 관리 ID + VNet에 Network Contributor
  $null = Initialize-Resource "관리 ID $($Cfg.Identity)" @('identity', 'show', '-g', $rg, '-n', $Cfg.Identity) {
    Invoke-Az (@('identity', 'create', '-g', $rg, '-n', $Cfg.Identity, '-l', $Cfg.Location) + $tags)
  }
  $identity = Invoke-Az @('identity', 'show', '-g', $rg, '-n', $Cfg.Identity, '-o', 'json')
  $vnetId = Invoke-Az @('network', 'vnet', 'show', '-g', $rg, '-n', $Cfg.Vnet, '--query', 'id', '-o', 'tsv')
  # az.cmd 는 cmd.exe 를 거치므로 --query 에 괄호를 쓰지 않는다
  $roleIds = @(Invoke-Az @('role', 'assignment', 'list', '--assignee', $identity.principalId, '--scope', $vnetId, '--role', 'Network Contributor', '--query', '[].id', '-o', 'json') | Where-Object { $_ })
  if ($roleIds.Count -gt 0) {
    Write-Host "이미 있음: $($Cfg.Identity) → VNet Network Contributor"
  } else {
    Write-Host "생성: $($Cfg.Identity) → VNet Network Contributor (전파 대기 60초)"
    $null = Invoke-Az @('role', 'assignment', 'create', '--assignee-object-id', $identity.principalId,
      '--assignee-principal-type', 'ServicePrincipal', '--role', 'Network Contributor', '--scope', $vnetId)
    Start-Sleep -Seconds 60
  }

  # Storage + Blob Private Endpoint + 사설 DNS
  $null = Initialize-Resource "Storage $($Cfg.Storage)" @('storage', 'account', 'show', '-g', $rg, '-n', $Cfg.Storage) {
    Invoke-Az (@('storage', 'account', 'create', '-g', $rg, '-n', $Cfg.Storage, '-l', $Cfg.Location,
        '--kind', 'StorageV2', '--sku', 'Standard_LRS', '--public-network-access', 'Disabled',
        '--allow-blob-public-access', 'false', '--min-tls-version', 'TLS1_2') + $tags)
  }
  $storageId = Invoke-Az @('storage', 'account', 'show', '-g', $rg, '-n', $Cfg.Storage, '--query', 'id', '-o', 'tsv')
  $null = Initialize-Resource "Private Endpoint $($Cfg.BlobPe)" @('network', 'private-endpoint', 'show', '-g', $rg, '-n', $Cfg.BlobPe) {
    Invoke-Az (@('network', 'private-endpoint', 'create', '-g', $rg, '-n', $Cfg.BlobPe, '-l', $Cfg.Location,
        '--vnet-name', $Cfg.Vnet, '--subnet', $Cfg.Subnets.pe.Name, '--private-connection-resource-id', $storageId,
        '--group-id', 'blob', '--connection-name', "$($Cfg.BlobPe)-conn") + $tags)
  }
  $null = Initialize-Resource "사설 DNS 영역 $($Cfg.BlobDnsZone)" @('network', 'private-dns', 'zone', 'show', '-g', $rg, '-n', $Cfg.BlobDnsZone) {
    Invoke-Az (@('network', 'private-dns', 'zone', 'create', '-g', $rg, '-n', $Cfg.BlobDnsZone) + $tags)
  }
  $null = Initialize-Resource "DNS VNet 링크 $($Cfg.BlobDnsLink)" @('network', 'private-dns', 'link', 'vnet', 'show', '-g', $rg, '--zone-name', $Cfg.BlobDnsZone, '-n', $Cfg.BlobDnsLink) {
    Invoke-Az (@('network', 'private-dns', 'link', 'vnet', 'create', '-g', $rg, '--zone-name', $Cfg.BlobDnsZone,
        '-n', $Cfg.BlobDnsLink, '--virtual-network', $Cfg.Vnet, '--registration-enabled', 'false') + $tags)
  }
  $null = Initialize-Resource "DNS zone group $($Cfg.BlobPe)/default" @('network', 'private-endpoint', 'dns-zone-group', 'show', '-g', $rg, '--endpoint-name', $Cfg.BlobPe, '-n', 'default') {
    Invoke-Az @('network', 'private-endpoint', 'dns-zone-group', 'create', '-g', $rg, '--endpoint-name', $Cfg.BlobPe,
      '-n', 'default', '--private-dns-zone', $Cfg.BlobDnsZone, '--zone-name', 'blob')
  }

  # VM 2대(공인 IP·NIC NSG 없음)
  foreach ($vm in @(@{ Name = $Cfg.VmAppgw; Subnet = $Cfg.Subnets.appgwSim.Name }, @{ Name = $Cfg.VmOther; Subnet = $Cfg.Subnets.other.Name })) {
    $null = Initialize-Resource "VM $($vm.Name)" @('vm', 'show', '-g', $rg, '-n', $vm.Name) {
      # '""' 는 az.cmd 에 빈 문자열로 전달된다('' 는 PowerShell이 버림)
      Invoke-Az (@('vm', 'create', '-g', $rg, '-n', $vm.Name, '-l', $Cfg.Location, '--image', 'Ubuntu2204',
          '--size', $Cfg.VmSize, '--vnet-name', $Cfg.Vnet, '--subnet', $vm.Subnet,
          '--public-ip-address', '""', '--nsg', '""', '--admin-username', 'azureuser', '--generate-ssh-keys') + $tags)
    }
  }

  # AKS
  $subnetId = Invoke-Az @('network', 'vnet', 'subnet', 'show', '-g', $rg, '--vnet-name', $Cfg.Vnet, '-n', $Cfg.Subnets.aksApp.Name, '--query', 'id', '-o', 'tsv')
  $null = Initialize-Resource "AKS $($Cfg.Aks)" @('aks', 'show', '-g', $rg, '-n', $Cfg.Aks) {
    Invoke-Az (@('aks', 'create', '-g', $rg, '-n', $Cfg.Aks, '-l', $Cfg.Location,
        '--network-plugin', 'azure', '--network-plugin-mode', 'overlay', '--network-dataplane', 'cilium',
        '--pod-cidr', $Cfg.PodCidr, '--vnet-subnet-id', $subnetId, '--assign-identity', $identity.id,
        '--enable-azure-service-mesh', '--tier', 'free',
        '--nodepool-name', 'system', '--node-count', '1', '--node-vm-size', $Cfg.SystemVmSize, '--zones', '1', '2', '3',
        '--nodepool-taints', 'CriticalAddonsOnly=true:NoSchedule',
        '--cluster-autoscaler-profile', 'balance-similar-node-groups=true') + $tags)
  }

  # 영역별 사용자 풀(크기·레이블·taint 동일)
  for ($i = 0; $i -lt $Cfg.UserPools.Count; $i++) {
    $pool = $Cfg.UserPools[$i]
    $zone = [string]($i + 1)
    $null = Initialize-Resource "노드 풀 $pool (영역 $zone)" @('aks', 'nodepool', 'show', '-g', $rg, '--cluster-name', $Cfg.Aks, '-n', $pool) {
      Invoke-Az (@('aks', 'nodepool', 'add', '-g', $rg, '--cluster-name', $Cfg.Aks, '-n', $pool,
          '--mode', 'User', '--zones', $zone, '--node-vm-size', $Cfg.UserVmSize, '--vnet-subnet-id', $subnetId,
          '--node-count', [string]$Cfg.UserMin, '--enable-cluster-autoscaler',
          '--min-count', [string]$Cfg.UserMin, '--max-count', [string]$Cfg.UserMax) + $tags)
    }
  }

  Write-Host '인프라 준비 완료'
  exit 0
} catch {
  Write-Host "오류: $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}
