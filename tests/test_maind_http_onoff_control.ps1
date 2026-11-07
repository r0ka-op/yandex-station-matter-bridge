[CmdletBinding()]
param([string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\maind_http_target_helpers.ps1')
Set-MaindHttpTarget -NodeId 258 -EndpointId 1
. (Join-Path $root 'scripts\maind_http_response_helpers.ps1')
. (Join-Path $root 'scripts\maind_http_onoff_control_helpers.ps1')
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $root `
        ('results\tests\maind-http-onoff-control-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

function Assert-True([bool]$Value, [string]$Message) {
    if (-not $Value) { throw $Message }
}
function Get-FreePort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start(); try { return $listener.LocalEndpoint.Port } finally { $listener.Stop() }
}

$port = Get-FreePort
$python = (Get-Command python -ErrorAction Stop).Source
$psi = [Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $python
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
foreach ($arg in @((Join-Path $root 'tests\maind_http_mock_server.py'),'--port',[string]$port)) {
    [void]$psi.ArgumentList.Add($arg)
}
$server = [Diagnostics.Process]::new(); $server.StartInfo = $psi
if (-not $server.Start()) { throw 'Mock server start failed' }
$stdoutTask = $server.StandardOutput.ReadToEndAsync()
$stderrTask = $server.StandardError.ReadToEndAsync()
$client = [Net.Http.HttpClient]::new(); $client.Timeout = [TimeSpan]::FromSeconds(5)
$calls = [Collections.Generic.List[string]]::new()

function Invoke-AllowlistedRequest([string]$Method,[string]$Path,[AllowNull()][string]$Body,[string]$Name) {
    Assert-MaindOnOffControlRequestAllowed -Method $Method -Path $Path -RequestBody $Body
    $calls.Add("$Method $Path")
    $request = [Net.Http.HttpRequestMessage]::new(
        [Net.Http.HttpMethod]::new($Method), "http://127.0.0.1:$port$Path")
    if ($null -ne $Body) {
        $request.Content = [Net.Http.StringContent]::new($Body,[Text.Encoding]::UTF8,'application/json')
    }
    try { $response = $client.SendAsync($request).GetAwaiter().GetResult() }
    finally { $request.Dispose() }
    $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    [IO.File]::WriteAllBytes((Join-Path $OutputDirectory "$Name.raw"),$bytes)
    if (-not $response.IsSuccessStatusCode -or $bytes.Length -eq 0) {
        throw "$Method $Path failed with HTTP $([int]$response.StatusCode)"
    }
    return [Text.Encoding]::UTF8.GetString($bytes)
}

try {
    $ready = $false
    for ($i=0;$i-lt 50;$i++) {
        try {$tcp=[Net.Sockets.TcpClient]::new('127.0.0.1',$port);$tcp.Dispose();$ready=$true;break}
        catch {Start-Sleep -Milliseconds 100}
    }
    Assert-True $ready 'Mock server not ready'

    $devicesRaw = Invoke-AllowlistedRequest GET /devices $null devices
    $devices = Get-MaindDevicesJsonAnalysis $devicesRaw 258
    Assert-True $devices.Analysis.target_found 'Node 258 missing before control sequence'
    $readBody = Get-MaindOnOffReadRequestJson
    $initialRaw = Invoke-AllowlistedRequest POST /interaction/readAttribute $readBody initial_read
    Assert-True (Test-Path (Join-Path $OutputDirectory 'initial_read.raw')) 'Initial raw body not saved'
    $initialState = Get-MaindOnOffStateFromReadResponse $initialRaw
    Assert-True (-not $initialState) 'Mock initial state must be false'

    $targetState = -not $initialState
    $changeId = Get-MaindOnOffCommandIdForState $targetState
    $changeBody = Get-MaindOnOffInvokeRequestJson $changeId
    [void](Invoke-AllowlistedRequest POST /interaction/invokeCommand $changeBody invoke_change)
    $changedRaw = Invoke-AllowlistedRequest POST /interaction/readAttribute $readBody changed_read
    Assert-True ((Get-MaindOnOffStateFromReadResponse $changedRaw) -eq $targetState) 'Change readback mismatch'

    $restoreId = Get-MaindOnOffCommandIdForState $initialState
    $restoreBody = Get-MaindOnOffInvokeRequestJson $restoreId
    [void](Invoke-AllowlistedRequest POST /interaction/invokeCommand $restoreBody invoke_restore)
    $restoredRaw = Invoke-AllowlistedRequest POST /interaction/readAttribute $readBody restored_read
    Assert-True ((Get-MaindOnOffStateFromReadResponse $restoredRaw) -eq $initialState) 'Restore readback mismatch'
    Assert-True (($calls -join ',') -ceq (
        'GET /devices,POST /interaction/readAttribute,POST /interaction/invokeCommand,' +
        'POST /interaction/readAttribute,POST /interaction/invokeCommand,' +
        'POST /interaction/readAttribute')) 'Control sequence order mismatch'

    foreach ($bad in @(
        @{m='POST';p='/interaction/invokeCommand';b='{"nodeId":258,"endpointId":2,"clusterId":6,"commandId":1,"fields":{}}'},
        @{m='POST';p='/interaction/invokeCommand';b='{"nodeId":258,"endpointId":1,"clusterId":8,"commandId":1,"fields":{}}'},
        @{m='POST';p='/interaction/invokeCommand';b='{"nodeId":258,"endpointId":1,"clusterId":6,"commandId":2,"fields":{}}'},
        @{m='POST';p='/interaction/invokeCommand';b='{"nodeId":258,"endpointId":1,"clusterId":6,"commandId":1,"fields":{"x":1}}'},
        @{m='POST';p='/interaction/writeAttribute';b='{}'},
        @{m='POST';p='/interaction/invokeGroupCommand';b='{}'},
        @{m='DELETE';p='/devices';b=$null}
    )) {
        Assert-True (-not (Test-MaindOnOffControlRequestAllowed -Method $bad.m -Path $bad.p -RequestBody $bad.b)) `
            "Forbidden control request allowed: $($bad.m) $($bad.p)"
    }

    [ordered]@{
        completed_utc=[DateTime]::UtcNow.ToString('o')
        real_matter_api_used=$false
        all_pass=$true
        initial_state=$initialState
        changed_state=$targetState
        restored_state=$initialState
        change_command_id=$changeId
        restore_command_id=$restoreId
        raw_saved_before_parse=$true
        sequence=@($calls)
        rollback_model='restoration verified before API rollback'
    } | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 `
        (Join-Path $OutputDirectory 'results.json')
    Write-Host 'ONOFF_CONTROL_MOCK=PASS'
    Write-Host "RESULTS=$OutputDirectory"
} finally {
    $client.Dispose()
    if (-not $server.HasExited) {$server.Kill($true)}
    $server.WaitForExit()
    $stdoutTask.GetAwaiter().GetResult() | Set-Content -Encoding UTF8 `
        (Join-Path $OutputDirectory 'mock.stdout.txt')
    $stderrTask.GetAwaiter().GetResult() | Set-Content -Encoding UTF8 `
        (Join-Path $OutputDirectory 'mock.stderr.txt')
    $server.Dispose()
}
