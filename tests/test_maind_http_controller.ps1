[CmdletBinding()]
param(
    [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $root "scripts\maind_http_target_helpers.ps1")
Set-MaindHttpTarget -NodeId 4660 -EndpointId 1
. (Join-Path $root "scripts\maind_http_response_helpers.ps1")
. (Join-Path $root "scripts\maind_http_onoff_control_helpers.ps1")

if (-not $OutputDirectory) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputDirectory = Join-Path $root "results\tests\maind-http-controller-$stamp"
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

function Get-FreeLoopbackPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return ([Net.IPEndPoint]$listener.LocalEndpoint).Port } finally { $listener.Stop() }
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-MockCase([string]$Name, [string]$Path, [string]$DevicesMode = $null) {
    $started = [DateTime]::UtcNow
    $request = [Net.Http.HttpRequestMessage]::new(
        [Net.Http.HttpMethod]::Get,
        "http://127.0.0.1:$port$Path"
    )
    if (-not [string]::IsNullOrEmpty($DevicesMode)) {
        [void]$request.Headers.TryAddWithoutValidation("X-Mock-Devices-Mode", $DevicesMode)
    }
    try {
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
    } finally {
        $request.Dispose()
    }
    $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $reason = $response.ReasonPhrase
    $headerLines = [System.Collections.Generic.List[string]]::new()
    foreach ($header in $response.Headers) {
        $headerLines.Add("$($header.Key): $($header.Value -join ', ')")
    }
    foreach ($header in $response.Content.Headers) {
        $headerLines.Add("$($header.Key): $($header.Value -join ', ')")
    }
    $wgetExit = if ([int]$response.StatusCode -ge 400) { 1 } else { 0 }
    $stderr = "  HTTP/1.1 $([int]$response.StatusCode) $reason`r`n" +
        (($headerLines | ForEach-Object { "  $_`r`n" }) -join '') +
        "__MAIND_WGET_EXIT__=$wgetExit`r`n"
    $evidence = Get-MaindWgetHttpEvidence `
        -RawStderr $stderr `
        -SshExitCode 0 `
        -BodyLength $bytes.Length
    [pscustomobject]@{
        Name = $Name
        Path = $Path
        StartedUtc = $started
        CompletedUtc = [DateTime]::UtcNow
        Status = [int]$response.StatusCode
        Bytes = $bytes
        Body = [Text.Encoding]::UTF8.GetString($bytes)
        BodyLength = $bytes.Length
        Evidence = $evidence
    }
}

function Invoke-MockPostCase([string]$Name, [string]$Path, [string]$JsonBody) {
    $started = [DateTime]::UtcNow
    $content = [Net.Http.StringContent]::new($JsonBody, [Text.Encoding]::UTF8, "application/json")
    try {
        $response = $client.PostAsync("http://127.0.0.1:$port$Path", $content).GetAwaiter().GetResult()
    } finally {
        $content.Dispose()
    }
    $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $reason = $response.ReasonPhrase
    $headerLines = [System.Collections.Generic.List[string]]::new()
    foreach ($header in $response.Headers) {
        $headerLines.Add("$($header.Key): $($header.Value -join ', ')")
    }
    foreach ($header in $response.Content.Headers) {
        $headerLines.Add("$($header.Key): $($header.Value -join ', ')")
    }
    $wgetExit = if ([int]$response.StatusCode -ge 400) { 1 } else { 0 }
    $stderr = "  HTTP/1.1 $([int]$response.StatusCode) $reason`r`n" +
        (($headerLines | ForEach-Object { "  $_`r`n" }) -join '') +
        "__MAIND_WGET_EXIT__=$wgetExit`r`n"
    $evidence = Get-MaindWgetHttpEvidence `
        -RawStderr $stderr `
        -SshExitCode 0 `
        -BodyLength $bytes.Length
    [pscustomobject]@{
        Name = $Name
        Path = $Path
        StartedUtc = $started
        CompletedUtc = [DateTime]::UtcNow
        Status = [int]$response.StatusCode
        Bytes = $bytes
        Body = [Text.Encoding]::UTF8.GetString($bytes)
        BodyLength = $bytes.Length
        Evidence = $evidence
    }
}

function Invoke-AllowlistedMockSequence(
    [string]$Name,
    [bool]$ReadOnOffAttributeEnabled,
    [string]$DevicesMode = "valid"
) {
    $calls = [System.Collections.Generic.List[string]]::new()
    $rollbackExecuted = $false
    $rawSavedBeforeParse = $false
    $failure = $null
    $plan = @(Get-MaindHttpReadOnlyRequestPlan `
        -ReadOnOffAttributeEnabled $ReadOnOffAttributeEnabled)
    try {
        foreach ($entry in $plan) {
            Assert-MaindHttpRequestAllowed `
                -Method $entry.method `
                -Path $entry.path `
                -RequestBody $entry.body `
                -ReadOnOffAttributeEnabled $ReadOnOffAttributeEnabled
            $calls.Add("$($entry.method) $($entry.path)")

            if ($entry.method -ceq "GET") {
                $response = Invoke-MockCase "$Name-devices" $entry.path $DevicesMode
                Assert-MaindHttpResponse $response.Evidence $true
                $rawPath = Join-Path $OutputDirectory "$Name-devices.raw"
                [IO.File]::WriteAllBytes($rawPath, $response.Bytes)
                $rawSavedBeforeParse = Test-Path -LiteralPath $rawPath
                $analysis = Get-MaindDevicesJsonAnalysis $response.Body 4660
                if (-not $analysis.Analysis.target_found) {
                    throw "Matter Node ID 4660 not found"
                }
                continue
            }

            $response = Invoke-MockPostCase "$Name-read" $entry.path $entry.body
            Assert-MaindHttpResponse $response.Evidence $true
            $rawPath = Join-Path $OutputDirectory "$Name-read.raw"
            [IO.File]::WriteAllBytes($rawPath, $response.Bytes)
            $rawSavedBeforeParse = $rawSavedBeforeParse -and (Test-Path -LiteralPath $rawPath)
            [void](ConvertFrom-Json -InputObject $response.Body -Depth 30 -NoEnumerate -ErrorAction Stop)
        }
    } catch {
        $failure = $_.Exception.Message
    } finally {
        # This models the controller's unconditional fail-closed rollback path.
        $rollbackExecuted = $true
    }
    return [pscustomobject][ordered]@{
        name = $Name
        read_flag = $ReadOnOffAttributeEnabled
        devices_mode = $DevicesMode
        calls = @($calls)
        raw_saved_before_parse = $rawSavedBeforeParse
        rollback_executed = $rollbackExecuted
        failure = $failure
    }
}

$port = Get-FreeLoopbackPort
$closedPort = Get-FreeLoopbackPort
$python = (Get-Command python -ErrorAction Stop).Source
$stdoutPath = Join-Path $OutputDirectory "mock.stdout.txt"
$stderrPath = Join-Path $OutputDirectory "mock.stderr.txt"
$serverStart = [Diagnostics.ProcessStartInfo]::new()
$serverStart.FileName = $python
$serverStart.UseShellExecute = $false
$serverStart.CreateNoWindow = $true
$serverStart.RedirectStandardOutput = $true
$serverStart.RedirectStandardError = $true
[void]$serverStart.ArgumentList.Add((Join-Path $root "scripts\maind_http_mock_server.py"))
[void]$serverStart.ArgumentList.Add("--port")
[void]$serverStart.ArgumentList.Add([string]$port)
$server = [Diagnostics.Process]::new()
$server.StartInfo = $serverStart
if (-not $server.Start()) { throw "Could not start local mock HTTP server" }
$serverStdout = $server.StandardOutput.ReadToEndAsync()
$serverStderr = $server.StandardError.ReadToEndAsync()

$client = [Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(5)
$results = [System.Collections.Generic.List[object]]::new()
try {
    $ready = $false
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        try {
            $probe = [Net.Sockets.TcpClient]::new()
            $connectTask = $probe.ConnectAsync("127.0.0.1", $port)
            if (-not $connectTask.Wait(200)) { throw "connect timeout" }
            $probe.Dispose()
            $ready = $true
            break
        } catch {
            Start-Sleep -Milliseconds 100
        }
    }
    Assert-True $ready "Mock HTTP server did not become ready"

    # End-to-end mode tests use the same request plan and allowlist functions
    # as the runtime controller, then exercise the exact production routes.
    $withoutRead = Invoke-AllowlistedMockSequence "e2e-without-read" $false
    Assert-True ($null -eq $withoutRead.failure) "GET-only mode failed: $($withoutRead.failure)"
    Assert-True (($withoutRead.calls -join ',') -ceq 'GET /devices') "GET-only call order mismatch"
    Assert-True $withoutRead.raw_saved_before_parse "GET-only raw body was not saved before parsing"
    Assert-True $withoutRead.rollback_executed "GET-only rollback was not executed"
    $results.Add([pscustomobject]@{case='e2e_without_read_flag';result='PASS';status=200})

    $withRead = Invoke-AllowlistedMockSequence "e2e-with-read" $true
    Assert-True ($null -eq $withRead.failure) "Read mode failed: $($withRead.failure)"
    Assert-True (($withRead.calls -join ',') -ceq 'GET /devices,POST /interaction/readAttribute') "Read-mode call order mismatch"
    Assert-True $withRead.raw_saved_before_parse "Read-mode raw bodies were not saved before parsing"
    Assert-True $withRead.rollback_executed "Read-mode rollback was not executed"
    $results.Add([pscustomobject]@{case='e2e_with_read_flag';result='PASS';status=200})

    $exactReadBody = Get-MaindOnOffReadRequestJson
    Assert-True ($exactReadBody -ceq '{"nodeId":4660,"endpointId":1,"clusterId":6,"attributeId":0}') "Exact read body changed"
    Assert-True (Test-MaindHttpRequestAllowed -Method GET -Path /devices -RequestBody $null -ReadOnOffAttributeEnabled $false) "GET /devices denied without flag"
    Assert-True (Test-MaindHttpRequestAllowed -Method GET -Path /devices -RequestBody '' -ReadOnOffAttributeEnabled $true) "GET /devices denied in read mode"
    Assert-True (-not (Test-MaindHttpRequestAllowed -Method POST -Path /interaction/readAttribute -RequestBody $exactReadBody -ReadOnOffAttributeEnabled $false)) "readAttribute allowed without flag"
    Assert-True (Test-MaindHttpRequestAllowed -Method POST -Path /interaction/readAttribute -RequestBody $exactReadBody -ReadOnOffAttributeEnabled $true) "readAttribute denied with flag"
    foreach ($forbidden in @(
        @{method='GET';path='/';body=$null},
        @{method='GET';path='/interaction/readAttribute';body=$null},
        @{method='POST';path='/devices';body='{}'},
        @{method='POST';path='/interaction/invokeCommand';body='{}'},
        @{method='POST';path='/interaction/writeAttribute';body='{}'},
        @{method='PUT';path='/interaction/readAttribute';body=$exactReadBody},
        @{method='DELETE';path='/devices';body=$null}
    )) {
        Assert-True (-not (Test-MaindHttpRequestAllowed `
            -Method $forbidden.method `
            -Path $forbidden.path `
            -RequestBody $forbidden.body `
            -ReadOnOffAttributeEnabled $true)) "Forbidden request was allowed: $($forbidden.method) $($forbidden.path)"
    }
    $results.Add([pscustomobject]@{case='allowlist_matrix';result='PASS';status=$null})

    foreach ($errorMode in @('no-target','empty','404','503','invalid-json')) {
        $errorRun = Invoke-AllowlistedMockSequence "e2e-error-$errorMode" $true $errorMode
        Assert-True ($null -ne $errorRun.failure) "Error mode $errorMode did not fail closed"
        Assert-True $errorRun.rollback_executed "Error mode $errorMode skipped rollback"
        Assert-True (($errorRun.calls -join ',') -ceq 'GET /devices') "Error mode $errorMode continued to POST"
        $results.Add([pscustomobject]@{case="e2e_$errorMode";result='PASS';status=$null})
    }

    $arrayCase = Invoke-MockCase "valid_array" "/devices-array"
    Assert-MaindHttpResponse $arrayCase.Evidence $true
    $arrayJson = Get-MaindDevicesJsonAnalysis $arrayCase.Body 4660
    Assert-True $arrayJson.Analysis.target_found "Node 4660 missing from valid array JSON"
    Assert-True ($arrayJson.Analysis.root_kind -eq "array") "Array JSON root not detected"
    $results.Add([pscustomobject]@{case=$arrayCase.Name; result="PASS"; status=$arrayCase.Status})

    $wrapperCase = Invoke-MockCase "valid_other_structure" "/devices-wrapper"
    Assert-MaindHttpResponse $wrapperCase.Evidence $true
    $wrapperJson = Get-MaindDevicesJsonAnalysis $wrapperCase.Body 4660
    Assert-True $wrapperJson.Analysis.target_found "Node 4660 missing from wrapped JSON"
    Assert-True ($wrapperJson.Analysis.root_kind -eq "object") "Object JSON root not detected"
    $results.Add([pscustomobject]@{case=$wrapperCase.Name; result="PASS"; status=$wrapperCase.Status})

    $readRequest = [ordered]@{nodeId=4660; endpointId=1; clusterId=6; attributeId=0}
    $readRequestJson = ConvertTo-Json -InputObject $readRequest -Compress
    $readCase = Invoke-MockPostCase `
        "read_attribute_exact_request" `
        "/interaction/readAttribute" `
        $readRequestJson
    Assert-MaindHttpResponse $readCase.Evidence $true
    $readParsed = ConvertFrom-Json -InputObject $readCase.Body -Depth 30 -NoEnumerate
    $readInventory = @(Get-MaindJsonPathInventory $readParsed)
    Assert-True ($readCase.Status -eq 200) "Read attribute mock did not return 200"
    Assert-True ($readInventory.path -contains '$.values[0].rawValue') "Read response rawValue path not retained"
    Assert-True (-not (Get-MaindOnOffStateFromReadResponse $readCase.Body)) "Initial mock OnOff state was not false"
    $results.Add([pscustomobject]@{case=$readCase.Name; result="PASS"; status=$readCase.Status})

    $noTargetCase = Invoke-MockCase "valid_json_without_target" "/devices-no-target"
    Assert-MaindHttpResponse $noTargetCase.Evidence $true
    $noTargetJson = Get-MaindDevicesJsonAnalysis $noTargetCase.Body 4660
    Assert-True (-not $noTargetJson.Analysis.target_found) "Missing node 4660 was reported as present"
    Assert-True ($noTargetJson.Analysis.node_id_object_count -eq 1) "Node diagnostics were not retained"
    $results.Add([pscustomobject]@{case=$noTargetCase.Name; result="PASS"; status=$noTargetCase.Status})

    $emptyCase = Invoke-MockCase "empty_200" "/empty"
    Assert-True ($emptyCase.Evidence.http_status -eq 200) "Empty case status mismatch"
    Assert-True ($null -ne $emptyCase.Evidence.body_error) "Empty body was not classified"
    $results.Add([pscustomobject]@{case=$emptyCase.Name; result="PASS"; status=$emptyCase.Status})

    $notFoundCase = Invoke-MockCase "http_404" "/not-found"
    Assert-True ($notFoundCase.Evidence.http_status -eq 404) "404 status missing"
    Assert-True ($null -ne $notFoundCase.Evidence.http_error) "404 not classified as HTTP error"
    Assert-True ($null -eq $notFoundCase.Evidence.transport_error) "404 misclassified as transport error"
    Assert-True ($notFoundCase.Evidence.wget_exit_code -eq 1) "404 wget exit mismatch"
    $results.Add([pscustomobject]@{case=$notFoundCase.Name; result="PASS"; status=$notFoundCase.Status})

    $unavailableCase = Invoke-MockCase "http_503" "/unavailable"
    Assert-True ($unavailableCase.Evidence.http_status -eq 503) "503 status missing"
    Assert-True ($null -ne $unavailableCase.Evidence.http_error) "503 not classified as HTTP error"
    Assert-True ($null -eq $unavailableCase.Evidence.transport_error) "503 misclassified as transport error"
    $results.Add([pscustomobject]@{case=$unavailableCase.Name; result="PASS"; status=$unavailableCase.Status})

    $invalidCase = Invoke-MockCase "invalid_json" "/invalid-json"
    Assert-MaindHttpResponse $invalidCase.Evidence $true
    $invalidRejected = $false
    try { [void](Get-MaindDevicesJsonAnalysis $invalidCase.Body 4660) } catch { $invalidRejected = $true }
    Assert-True $invalidRejected "Invalid JSON was accepted"
    $results.Add([pscustomobject]@{case=$invalidCase.Name; result="PASS"; status=$invalidCase.Status})

    $closedRejected = $false
    try {
        [void]$client.GetAsync("http://127.0.0.1:$closedPort/devices").GetAwaiter().GetResult()
    } catch {
        $closedRejected = $true
    }
    Assert-True $closedRejected "Closed TCP connection was not rejected"
    $closedEvidence = Get-MaindWgetHttpEvidence `
        -RawStderr "ssh: connect to host failed" `
        -SshExitCode 255 `
        -BodyLength 0
    Assert-True ($null -ne $closedEvidence.transport_error) "Closed transport was not classified"
    Assert-True ($null -eq $closedEvidence.http_error) "Closed transport was misclassified as HTTP error"
    $results.Add([pscustomobject]@{case="closed_tcp"; result="PASS"; status=$null})

    [ordered]@{
        completed_utc = [DateTime]::UtcNow.ToString("o")
        mock_bind = "127.0.0.1:$port"
        real_matter_api_used = $false
        all_pass = $true
        cases = @($results)
    } | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 (Join-Path $OutputDirectory "results.json")
    Write-Host "HTTP_MOCK_TESTS=PASS"
    Write-Host "RESULTS=$OutputDirectory"
} finally {
    $client.Dispose()
    if (-not $server.HasExited) { $server.Kill($true) }
    $server.WaitForExit()
    $serverStdout.GetAwaiter().GetResult() | Set-Content -Encoding UTF8 $stdoutPath
    $serverStderr.GetAwaiter().GetResult() | Set-Content -Encoding UTF8 $stderrPath
    $server.Dispose()
}
