[CmdletBinding()]
param([string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $root 'scripts\maind_http_target_helpers.ps1')
Set-MaindHttpTarget -NodeId 4660 -EndpointId 1
. (Join-Path $root 'scripts\maind_http_response_helpers.ps1')
. (Join-Path $root 'scripts\maind_http_capability_helpers.ps1')
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $root `
        ('results\tests\maind-http-capability-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

function Assert-True([bool]$Value,[string]$Message) { if (-not $Value) { throw $Message } }
function Get-FreePort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $listener.Start(); try { return $listener.LocalEndpoint.Port } finally { $listener.Stop() }
}

$port = Get-FreePort
$python = (Get-Command python -ErrorAction Stop).Source
$psi = [Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $python; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
foreach ($arg in @((Join-Path $root 'scripts\maind_http_mock_server.py'),'--port',[string]$port)) {
    [void]$psi.ArgumentList.Add($arg)
}
$server = [Diagnostics.Process]::new(); $server.StartInfo = $psi
if (-not $server.Start()) { throw 'Mock server start failed' }
$stdoutTask = $server.StandardOutput.ReadToEndAsync(); $stderrTask = $server.StandardError.ReadToEndAsync()
$client = [Net.Http.HttpClient]::new(); $client.Timeout = [TimeSpan]::FromSeconds(5)
$calls = [Collections.Generic.List[string]]::new()

function Invoke-MockCapabilityRead([UInt64]$ClusterId,[UInt64]$AttributeId,[string]$Mode,[string]$Name) {
    $body = Get-MaindCapabilityReadRequestJson -ClusterId $ClusterId -AttributeId $AttributeId
    Assert-MaindCapabilityRequestAllowed -Method POST -Path /interaction/readAttribute -RequestBody $body
    $calls.Add("$ClusterId/$AttributeId")
    $request = [Net.Http.HttpRequestMessage]::new(
        [Net.Http.HttpMethod]::Post,"http://127.0.0.1:$port/interaction/readAttribute")
    $request.Headers.Add('X-Mock-Capability-Mode',$Mode)
    $request.Content = [Net.Http.StringContent]::new($body,[Text.Encoding]::UTF8,'application/json')
    try { $response = $client.SendAsync($request).GetAwaiter().GetResult() }
    finally { $request.Dispose() }
    try {
        $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        [IO.File]::WriteAllBytes((Join-Path $OutputDirectory "$Name.raw"),$bytes)
        return [pscustomobject]@{
            status=[int]$response.StatusCode
            body=[Text.Encoding]::UTF8.GetString($bytes)
            length=$bytes.Length
        }
    } finally { $response.Dispose() }
}

function Read-SupportedAttribute([UInt64]$ClusterId,[UInt64]$AttributeId,[string]$Mode,[string]$Name) {
    $http = Invoke-MockCapabilityRead $ClusterId $AttributeId $Mode $Name
    if ($http.status -lt 200 -or $http.status -ge 300 -or $http.length -eq 0) {
        throw "Expected non-empty HTTP 2xx for $ClusterId/$AttributeId"
    }
    $attribute = Get-MaindAttributeResult -JsonText $http.body -ClusterId $ClusterId -AttributeId $AttributeId
    if (-not $attribute.supported) { return [pscustomobject]@{supported=$false;decoded=$null} }
    $decoded = ConvertFrom-MaindMatterTlv -RawValue $attribute.value.rawValue -Root $root
    return [pscustomobject]@{supported=$true;decoded=$decoded}
}

try {
    $ready=$false
    for($i=0;$i-lt 50;$i++){
        try{$tcp=[Net.Sockets.TcpClient]::new('127.0.0.1',$port);$tcp.Dispose();$ready=$true;break}
        catch{Start-Sleep -Milliseconds 100}
    }
    Assert-True $ready 'Mock server not ready'

    Assert-MaindCapabilityRequestAllowed -Method GET -Path /devices -RequestBody $null
    $devicesRequest = [Net.Http.HttpRequestMessage]::new(
        [Net.Http.HttpMethod]::Get,"http://127.0.0.1:$port/devices")
    try { $devicesResponse = $client.SendAsync($devicesRequest).GetAwaiter().GetResult() }
    finally { $devicesRequest.Dispose() }
    try {
        $devicesBytes = $devicesResponse.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        [IO.File]::WriteAllBytes((Join-Path $OutputDirectory 'devices.raw'),$devicesBytes)
        Assert-True $devicesResponse.IsSuccessStatusCode 'GET /devices failed'
        Assert-True ($devicesBytes.Length -gt 0) 'GET /devices body is empty'
        $devicesText = [Text.Encoding]::UTF8.GetString($devicesBytes)
        $devices = Get-MaindDevicesJsonAnalysis $devicesText 4660
        Assert-True $devices.Analysis.target_found 'Node 4660 absent before discovery'
        $calls.Add('GET /devices')
    } finally { $devicesResponse.Dispose() }
    $descriptor = Read-SupportedAttribute 29 1 full descriptor
    $serverList = @(Get-MaindServerListFromTlv $descriptor.decoded)
    Assert-True (($serverList -join ',') -ceq '29,6,8,768') 'ServerList TLV mismatch'

    foreach ($pair in @(@(8,0),@(8,65532),@(8,65529),
        @(768,16394),@(768,8),@(768,65532),@(768,65529),
        @(768,0),@(768,1),@(768,3),@(768,4),@(768,7))) {
        $item = Read-SupportedAttribute $pair[0] $pair[1] full ("pair-$($pair[0])-$($pair[1])")
        Assert-True $item.supported "Fixture unexpectedly unsupported: $($pair -join '/')"
        if ($pair[1] -eq 65529) { [void](Get-MaindUnsignedListFromTlv $item.decoded) }
        else { [void](Get-MaindUnsignedScalarFromTlv $item.decoded) }
    }

    $noLevel = Read-SupportedAttribute 29 1 no-level descriptor_no_level
    Assert-True (-not (8 -in @(Get-MaindServerListFromTlv $noLevel.decoded))) 'no-level gating failed'
    $noColor = Read-SupportedAttribute 29 1 no-color descriptor_no_color
    Assert-True (-not (768 -in @(Get-MaindServerListFromTlv $noColor.decoded))) 'no-color gating failed'

    $unsupported = Read-SupportedAttribute 8 0 unsupported-optional unsupported_optional
    Assert-True (-not $unsupported.supported) 'Unsupported attribute must remain diagnostic'
    foreach($pair in @(@(321911814,65529),@(321911814,65531),@(321911814,65532))){
        $vendor=Read-SupportedAttribute $pair[0] $pair[1] full ("vendor-$($pair[1])")
        Assert-True $vendor.supported "Vendor global attribute fixture failed: $($pair[1])"
    }

    foreach ($scenario in @(
        @{mode='http-404';status=404;name='http_404'},
        @{mode='http-503';status=503;name='http_503'},
        @{mode='empty';status=200;name='empty'},
        @{mode='invalid-json';status=200;name='invalid_json'}
    )) {
        $http = Invoke-MockCapabilityRead 29 1 $scenario.mode $scenario.name
        Assert-True ($http.status -eq $scenario.status) "HTTP status mismatch: $($scenario.mode)"
        if ($scenario.mode -eq 'empty') { Assert-True ($http.length -eq 0) 'Empty body fixture failed' }
        if ($scenario.mode -eq 'invalid-json') {
            $rejected=$false; try {[void](Get-MaindAttributeResult $http.body 29 1)}catch{$rejected=$true}
            Assert-True $rejected 'Invalid JSON was accepted'
        }
    }
    $tlvRejected=$false
    try {[void](Read-SupportedAttribute 29 1 malformed-tlv malformed_tlv)}catch{$tlvRejected=$true}
    Assert-True $tlvRejected 'Malformed ServerList TLV was accepted'

    $closedPort = Get-FreePort
    $transportRejected=$false
    try {[void]$client.GetAsync("http://127.0.0.1:$closedPort/devices").GetAwaiter().GetResult()}
    catch {$transportRejected=$true}
    Assert-True $transportRejected 'Closed TCP connection was not classified as transport failure'

    foreach ($bad in @(
        @{m='POST';p='/interaction/invokeCommand';b='{}'},
        @{m='POST';p='/interaction/writeAttribute';b='{}'},
        @{m='POST';p='/interaction/readAttribute';b='{"nodeId":4660,"endpointId":2,"clusterId":29,"attributeId":1}'},
        @{m='POST';p='/interaction/readAttribute';b='{"nodeId":4660,"endpointId":1,"clusterId":6,"attributeId":0}'},
        @{m='DELETE';p='/devices';b=$null}
    )) {
        Assert-True (-not (Test-MaindCapabilityRequestAllowed -Method $bad.m -Path $bad.p -RequestBody $bad.b)) `
            "Forbidden request allowed: $($bad.m) $($bad.p)"
    }

    [ordered]@{
        completed_utc=[DateTime]::UtcNow.ToString('o'); all_pass=$true
        real_matter_api_used=$false; server_list=$serverList
        conditional_gating=$true; unsupported_is_diagnostic=$true
        http_cases=@('200','404','503','empty','invalid-json')
        forbidden_routes_rejected=$true; calls=@($calls)
    } | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 `
        (Join-Path $OutputDirectory 'results.json')
    Write-Host 'CAPABILITY_DISCOVERY_MOCK=PASS'
    Write-Host "RESULTS=$OutputDirectory"
} finally {
    $client.Dispose()
    if (-not $server.HasExited) {$server.Kill($true)}
    $server.WaitForExit()
    $stdoutTask.GetAwaiter().GetResult() | Set-Content -Encoding UTF8 (Join-Path $OutputDirectory 'mock.stdout.txt')
    $stderrTask.GetAwaiter().GetResult() | Set-Content -Encoding UTF8 (Join-Path $OutputDirectory 'mock.stderr.txt')
    $server.Dispose()
}
