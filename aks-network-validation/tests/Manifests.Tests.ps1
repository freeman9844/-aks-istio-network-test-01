BeforeAll {
  $script:Dir = Join-Path $PSScriptRoot '../manifests'
  function Get-Text([string]$Name) {
    $path = Join-Path $script:Dir $Name
    if (-not (Test-Path $path)) { throw "매니페스트 없음: $Name" }
    return Get-Content -Raw $path
  }
  function Get-Count([string]$Text, [string]$Pattern) {
    return ([regex]::Matches($Text, $Pattern, 'Multiline')).Count
  }
}

Describe 'Service 포트 이름' {
  It '<_>: kind: Service 수 = name: http 수' -ForEach @('10-web.yaml', '11-app.yaml') {
    $t = Get-Text $_
    $svc = Get-Count $t '^kind:\s*Service\s*$'
    $svc | Should -BeGreaterThan 0
    Get-Count $t '^\s*(-\s*)?name:\s*http\s*$' | Should -Be $svc
  }
}

Describe 'serviceAccountName' {
  It '<_>: Deployment마다 serviceAccountName' -ForEach @('10-web.yaml', '11-app.yaml', '12-nomesh.yaml', '40-scale.yaml') {
    $t = Get-Text $_
    $dep = Get-Count $t '^kind:\s*Deployment\s*$'
    $dep | Should -BeGreaterThan 0
    Get-Count $t '^\s*serviceAccountName:\s*\S+' | Should -Be $dep
  }
}

Describe '40-scale.yaml' {
  It '<_> 포함' -ForEach @('minReplicas: 5', 'maxReplicas: 5', 'type: Pods', 'value: 1', 'periodSeconds: 60', 'averageUtilization: 70', 'cpu: 800m') {
    (Get-Text '40-scale.yaml') | Should -Match ([regex]::Escape($_))
  }
}

Describe '30-netpol.yaml' {
  It 'name·namespace' {
    $t = Get-Text '30-netpol.yaml'
    $t | Should -Match 'name:\s*deny-web-to-data'
    $t | Should -Match 'namespace:\s*web\b'
  }
  It 'except 뒤 10.50.2.0/24' {
    (Get-Text '30-netpol.yaml') | Should -Match '(?s)except:\s*\r?\n\s*-\s*10\.50\.2\.0/24'
  }
}

Describe '20-istio.yaml' {
  It '<_> 포함' -ForEach @('cluster.local/ns/web/sa/web-a', 'cluster.local/ns/web/sa/web-b', '__GATEWAY_PRINCIPAL__', 'istio: aks-istio-ingressgateway-internal') {
    (Get-Text '20-istio.yaml') | Should -Match ([regex]::Escape($_))
  }
  It 'mode: STRICT 2회' {
    Get-Count (Get-Text '20-istio.yaml') 'mode:\s*STRICT' | Should -Be 2
  }
}

Describe 'readinessProbe' {
  It '<_>: Deployment마다 readinessProbe' -ForEach @('10-web.yaml', '11-app.yaml') {
    $t = Get-Text $_
    Get-Count $t '^\s*readinessProbe:' | Should -Be (Get-Count $t '^kind:\s*Deployment\s*$')
  }
}

Describe '40-scale.yaml 영역 분산(T12b·T13b)' {
  It 'hpa-demo 는 replicas 를 두지 않음(HPA 가 관리)' {
    (Get-Text '40-scale.yaml') | Should -Not -Match '(?m)^\s*replicas:\s*5\s*$'
  }
  It 'DoNotSchedule + minDomains 3 이 hpa-demo·zone-spread 2곳' {
    $t = Get-Text '40-scale.yaml'
    Get-Count $t 'whenUnsatisfiable:\s*DoNotSchedule' | Should -Be 2
    Get-Count $t 'minDomains:\s*3' | Should -Be 2
    Get-Count $t 'nodeTaintsPolicy:\s*Honor' | Should -Be 2
  }
  It 'zone-spread Deployment 존재, 평소 0개' {
    (Get-Text '40-scale.yaml') | Should -Match '(?s)name:\s*zone-spread\s*\r?\n\s*namespace:\s*scale\s*\r?\nspec:\s*\r?\n\s*replicas:\s*0'
  }
}
