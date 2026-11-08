[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfirmToken,
    [Parameter(Mandatory=$true)][string]$SshAlias,
    [Parameter(Mandatory=$true)][string]$StationIPv4,
    [Parameter(Mandatory=$true)][string]$StationIPv6,
    [Parameter(Mandatory=$true)][ValidateRange(1,[UInt64]::MaxValue)][UInt64]$MatterNodeId,
    [ValidateRange(0,65535)][UInt16]$MatterEndpointId=1,
    [switch]$StagingOnly,
    [switch]$ReadOnOffAttribute,
    [switch]$ReadLightStateVerification,
    [string]$LightStateVerificationToken,
    [switch]$CapabilityDiscovery,
    [switch]$VendorColorMusicDiscovery,
    [switch]$InternalOnOffControl,
    [string]$ControlConfirmToken,
    [switch]$InternalBrightnessControl,
    [switch]$InternalVisualBrightnessControl,
    [switch]$InternalColorControl,
    [switch]$InternalVisualColorControl,
    [switch]$InternalFullInventory,
    [UInt64]$InventoryTargetNodeId=0,
    [ValidateRange(1,5000)][int]$InventoryMaxRequests=1000,
    [ValidateRange(1024,4194304)][int]$InventoryMaxResponseBytes=1048576,
    [ValidateRange(1048576,268435456)][long]$InventoryMaxTotalBytes=67108864,
    [ValidateRange(0,5000)][int]$InventoryRequestDelayMs=150,
    [ValidateRange(60,1800)][int]$InventoryMaxSessionSeconds=600,
    [string]$LightControlConfirmToken,
    [switch]$AllowTemporaryOn,
    [string]$TemporaryOnConfirmToken
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$requiredToken = "I_APPROVE_MAIND_HTTP_RUNTIME_TEST"
if ($ConfirmToken -cne $requiredToken) {
    throw "Refusing to run: exact confirmation token required."
}

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $root "scripts\maind_http_target_helpers.ps1")
Set-MaindHttpTarget -NodeId $MatterNodeId -EndpointId $MatterEndpointId
. (Join-Path $root "scripts\maind_http_response_helpers.ps1")
. (Join-Path $root "scripts\maind_http_onoff_control_helpers.ps1")
. (Join-Path $root "scripts\maind_http_capability_helpers.ps1")
. (Join-Path $root "scripts\maind_http_light_control_helpers.ps1")
. (Join-Path $root "scripts\maind_http_light_state_verification_helpers.ps1")
. (Join-Path $root "scripts\maind_http_inventory_helpers.ps1")
$controlEnabled = [bool]$InternalOnOffControl.IsPresent
$capabilityEnabled = [bool]$CapabilityDiscovery.IsPresent
$vendorDiscoveryEnabled = [bool]$VendorColorMusicDiscovery.IsPresent
$brightnessEnabled = [bool]$InternalBrightnessControl.IsPresent
$visualBrightnessEnabled = [bool]$InternalVisualBrightnessControl.IsPresent
$colorEnabled = [bool]$InternalColorControl.IsPresent
$visualColorEnabled = [bool]$InternalVisualColorControl.IsPresent
$inventoryEnabled = [bool]$InternalFullInventory.IsPresent
if($InventoryTargetNodeId -eq 0){$InventoryTargetNodeId=$MatterNodeId}
$inventoryContext = if($inventoryEnabled){New-MaindInventoryContext -NodeId $InventoryTargetNodeId}else{$null}
$lightMode = if ($brightnessEnabled) {'brightness'} elseif ($colorEnabled) {'color'} else {$null}
$lightControlEnabled = [bool]($brightnessEnabled -or $colorEnabled)
$lightStateVerificationEnabled = [bool]$ReadLightStateVerification.IsPresent
if ($lightStateVerificationEnabled -and
    $LightStateVerificationToken -cne 'I_APPROVE_READ_ONLY_LIGHT_STATE_VERIFICATION') {
    throw 'Refusing light-state verification: exact read-only token required.'
}
if ($controlEnabled -and $ControlConfirmToken -cne 'I_APPROVE_SINGLE_ONOFF_CHANGE_AND_RESTORE') {
    throw 'Refusing internal control mode: exact control confirmation token required.'
}
if ($visualBrightnessEnabled -and -not $brightnessEnabled) {
    throw 'Visual brightness mode requires brightness control mode.'
}
if ($visualColorEnabled -and -not $colorEnabled) {
    throw 'Visual color mode requires color control mode.'
}
$brightnessToken = if ($visualBrightnessEnabled) {
    'I_APPROVE_VISUAL_BRIGHTNESS_64_AND_RESTORE'
} else {
    'I_APPROVE_SMALL_BRIGHTNESS_CHANGE_AND_RESTORE'
}
if ($brightnessEnabled -and $LightControlConfirmToken -cne $brightnessToken) {
    throw 'Refusing brightness mode: exact mode-specific confirmation token required.'
}
$colorToken = if ($visualColorEnabled) {
    'I_APPROVE_VISUAL_COLOR_85_LEVEL_64_AND_RESTORE'
} else {
    'I_APPROVE_SMALL_COLOR_CHANGE_AND_RESTORE'
}
if ($colorEnabled -and $LightControlConfirmToken -cne $colorToken) {
    throw 'Refusing color mode: exact confirmation token required.'
}
if ($AllowTemporaryOn -and (-not $lightControlEnabled -or
    $TemporaryOnConfirmToken -cne 'I_APPROVE_TEMPORARY_ON_AND_RESTORE')) {
    throw 'Temporary On requires a light experiment and its separate exact token.'
}
$selectedModeCount = [int]$controlEnabled + [int]$ReadOnOffAttribute.IsPresent +
    [int]$lightStateVerificationEnabled + [int]$capabilityEnabled + [int]$vendorDiscoveryEnabled +
    [int]$brightnessEnabled + [int]$colorEnabled + [int]$inventoryEnabled
if ($selectedModeCount -gt 1) {
    throw 'Runtime experiment modes are mutually exclusive.'
}
$readOnOffEnabled = [bool]($ReadOnOffAttribute.IsPresent -or $controlEnabled)
$httpRequestPlan = @(Get-MaindHttpReadOnlyRequestPlan `
    -ReadOnOffAttributeEnabled $readOnOffEnabled)
foreach ($plannedRequest in $httpRequestPlan) {
    if ($inventoryEnabled) {
        Assert-MaindInventoryRequestAllowed -Context $inventoryContext -Method $plannedRequest.method `
            -Path $plannedRequest.path -RequestBody $plannedRequest.body
    } elseif ($lightStateVerificationEnabled) {
        Assert-MaindLightStateVerificationRequestAllowed -Method $plannedRequest.method `
            -Path $plannedRequest.path -RequestBody $plannedRequest.body
    } elseif ($capabilityEnabled -or $vendorDiscoveryEnabled) {
        Assert-MaindCapabilityRequestAllowed -Method $plannedRequest.method `
            -Path $plannedRequest.path -RequestBody $plannedRequest.body
    } elseif ($lightControlEnabled) {
        Assert-MaindLightControlRequestAllowed -Mode $lightMode `
            -Method $plannedRequest.method -Path $plannedRequest.path `
            -RequestBody $plannedRequest.body -TemporaryOnAllowed ([bool]$AllowTemporaryOn)
    } elseif ($controlEnabled) {
        Assert-MaindOnOffControlRequestAllowed -Method $plannedRequest.method `
            -Path $plannedRequest.path -RequestBody $plannedRequest.body
    } else {
        Assert-MaindHttpRequestAllowed `
            -Method $plannedRequest.method `
            -Path $plannedRequest.path `
            -RequestBody $plannedRequest.body `
            -ReadOnOffAttributeEnabled $readOnOffEnabled
    }
}
$runStamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
$runId = "run-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))-$(([Guid]::NewGuid().ToString('N')).Substring(0,12))"
$remoteScript = Join-Path $root "scripts\maind_http_runtime_test_remote.sh"
$ssh = Join-Path $env:WINDIR "System32\OpenSSH\ssh.exe"
$remotePath = if ($StagingOnly) {
    "/tmp/maind_http_runtime_test_remote.$runId.staging-test.sh"
} else {
    "/tmp/maind_http_runtime_test_remote.$runId.sh"
}
$remoteBase = "/tmp/maind-http-runs/$runId"
$remoteHelperCommand = "MAIND_HTTP_RUN_ID=$runId MAIND_HTTP_BASE=$remoteBase MAIND_HTTP_NODE_ID=$MatterNodeId MAIND_HTTP_ENDPOINT_ID=$MatterEndpointId '$remotePath'"
$stagingAttempted = $false
$helperUploaded = $false
$helperValidated = $false
$activationCommandIssued = $false
$originalOnOffState = $null
$changeCommandAttempted = $false
$restorationVerified = $false
$oldMarkerEvidence = $null
$lightInitialOnOff = $null
$lightInitialLevel = $null
$lightMutationMayHaveOccurred = $false
$visualColorRestoreLevel = -1
$resultDir = if($inventoryEnabled){
    Join-Path $root "results\private\inventory-$runStamp"
}else{
    Join-Path $root "results\runtime\maind-http-$runStamp"
}
New-Item -ItemType Directory -Path $resultDir -Force | Out-Null
[ordered]@{run_id=$runId;remote_base=$remoteBase;remote_helper=$remotePath;created_utc=[DateTime]::UtcNow.ToString('o')} |
    ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $resultDir 'run_identity.json')

function Invoke-Ssh([string]$Command) {
    & $ssh -o BatchMode=yes -o ConnectTimeout=10 $SshAlias $Command
    if ($LASTEXITCODE -ne 0) { throw "SSH command failed: $Command" }
}

function Invoke-SshCaptured([string]$Command) {
    $psi=[Diagnostics.ProcessStartInfo]::new()
    $psi.FileName=$ssh
    $psi.UseShellExecute=$false
    $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true
    $psi.RedirectStandardError=$true
    foreach($argument in @('-o','BatchMode=yes','-o','ConnectTimeout=10',$SshAlias,$Command)){
        [void]$psi.ArgumentList.Add($argument)
    }
    $process=[Diagnostics.Process]::new();$process.StartInfo=$psi
    if(-not$process.Start()){throw 'Could not start captured SSH command'}
    try{
        $stdoutTask=$process.StandardOutput.ReadToEndAsync()
        $stderrTask=$process.StandardError.ReadToEndAsync()
        if(-not$process.WaitForExit(30000)){
            $process.Kill($true);$process.WaitForExit()
            throw 'Captured SSH command timed out after 30 seconds'
        }
        [pscustomobject]@{
            exit_code=$process.ExitCode
            stdout=$stdoutTask.GetAwaiter().GetResult()
            stderr=$stderrTask.GetAwaiter().GetResult()
        }
    }finally{$process.Dispose()}
}

function ConvertFrom-LifecycleRefusal([string]$Stdout,[string]$Stderr,[int]$ExitCode){
    $combined=($Stdout+"`n"+$Stderr)
    $line=@($combined -split '\r?\n'|Where-Object{$_-like'*MAIND_PREFLIGHT_REFUSAL|*'}|Select-Object -Last 1)
    if($line.Count-eq0){
        return [pscustomobject][ordered]@{
            parsed=$false;exit_code=$ExitCode;code='PF_UNSTRUCTURED_REMOTE_FAILURE'
            stage='remote_preflight';condition='unknown';system_changed='unknown'
            action='inspect_lifecycle_preflight_json'
            detail=(($combined.Trim()) -replace '[\r\n]+','; ')
        }
    }
    $payload=$line[0].Substring($line[0].IndexOf('MAIND_PREFLIGHT_REFUSAL|'))
    $values=@{}
    foreach($part in $payload.Split('|')|Select-Object -Skip 1){
        $separator=$part.IndexOf('=')
        if($separator-gt0){$values[$part.Substring(0,$separator)]=$part.Substring($separator+1)}
    }
    [pscustomobject][ordered]@{
        parsed=$true;exit_code=$ExitCode
        code=if($values.ContainsKey('code')){$values.code}else{'PF_MALFORMED_STRUCTURED_FAILURE'}
        stage=if($values.ContainsKey('stage')){$values.stage}else{'unknown'}
        condition=if($values.ContainsKey('condition')){$values.condition}else{'unknown'}
        system_changed=if($values.ContainsKey('system_changed')){$values.system_changed}else{'unknown'}
        action=if($values.ContainsKey('action')){$values.action}else{'inspect_raw_preflight'}
        detail=if($values.ContainsKey('detail')){$values.detail}else{'missing_detail'}
    }
}

function Send-FileOverSshStdin([string]$LocalPath, [string]$RemoteTarget) {
    # Do not use a PowerShell text pipeline here. The local file is read as raw
    # bytes and written directly to ssh.exe's stdin BaseStream.
    $bytes = [System.IO.File]::ReadAllBytes($LocalPath)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $ssh
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($argument in @(
        "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", $SshAlias,
        "umask 077; cat > '$RemoteTarget'"
    )) {
        [void]$psi.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    if (-not $process.Start()) { throw "Could not start ssh byte transport" }
    try {
        $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $process.StandardInput.BaseStream.Flush()
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "SSH stdin staging failed (exit $($process.ExitCode)): $stderr"
        }
        if ($stdout) { Write-Verbose $stdout }
    } finally {
        $process.Dispose()
    }
    return $bytes.Length
}

function Receive-DirectoryOverSshTar([string]$RemoteDirectory, [string]$LocalDirectory) {
    # RemoteDirectory is a Linux path. Do not pass it through PowerShell's
    # Windows filesystem provider (Split-Path would turn /tmp into \tmp).
    if ($RemoteDirectory -notmatch '^/[A-Za-z0-9._/-]+$') {
        throw "Unsafe or non-absolute remote Linux path: $RemoteDirectory"
    }
    $remoteNormalized = $RemoteDirectory.TrimEnd('/')
    $lastSlash = $remoteNormalized.LastIndexOf('/')
    if ($lastSlash -lt 0) { throw "Remote Linux path has no parent" }
    $leaf = $remoteNormalized.Substring($lastSlash + 1)
    $parent = if ($lastSlash -eq 0) { "/" } else { $remoteNormalized.Substring(0, $lastSlash) }
    if (-not $leaf -or $leaf -in @('.', '..')) { throw "Unsafe remote archive leaf" }
    $archive = Join-Path $LocalDirectory "$leaf.tar"
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $ssh
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($argument in @(
        "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", $SshAlias,
        "tar -C '$parent' -cf - '$leaf'"
    )) {
        [void]$psi.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    if (-not $process.Start()) { throw "Could not start SSH result transport" }
    try {
        $stderrTask=$process.StandardError.ReadToEndAsync()
        $stream = [System.IO.File]::Open($archive, [System.IO.FileMode]::Create)
        try {
            $copyTask=$process.StandardOutput.BaseStream.CopyToAsync($stream)
            if(-not $process.WaitForExit(90000)){
                $process.Kill($true);$process.WaitForExit()
                throw 'SSH tar retrieval timed out after 90 seconds'
            }
            [void]$copyTask.GetAwaiter().GetResult()
        } finally { $stream.Dispose() }
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "SSH tar retrieval failed (exit $($process.ExitCode)): $stderr"
        }
    } finally {
        $process.Dispose()
    }

    if ((Get-Item -LiteralPath $archive).Length -le 0) {
        throw "SSH returned an empty tar archive"
    }
    $archiveEntries = @(& tar.exe -tf $archive)
    if ($LASTEXITCODE -ne 0) { throw "Received SSH tar archive failed integrity listing" }
    if ($archiveEntries.Count -eq 0) { throw "Received SSH tar archive has no entries" }
    foreach ($entryValue in $archiveEntries) {
        $entry = ([string]$entryValue).Replace('\', '/')
        $segments = @($entry.Split('/', [System.StringSplitOptions]::RemoveEmptyEntries))
        if ($entry.StartsWith('/') -or $segments -contains '..' -or
            -not ($entry -eq $leaf -or $entry.StartsWith("$leaf/"))) {
            throw "Unsafe entry in received SSH tar archive: $entry"
        }
    }
    & tar.exe -xf $archive -C $LocalDirectory
    if ($LASTEXITCODE -ne 0) { throw "Could not extract SSH tar result" }
}

function Remove-PartialStaging() {
    try {
        & $ssh -o BatchMode=yes -o ConnectTimeout=10 $SshAlias "rm -f '$remotePath'"
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Remote cleanup returned exit code $LASTEXITCODE"
        }
    } catch {
        Write-Warning "Could not remove partial staging file: $_"
    }
}

function Test-TcpBlocked([System.Net.IPAddress]$Address, [int]$Port) {
    $client = [System.Net.Sockets.TcpClient]::new($Address.AddressFamily)
    try {
        $task = $client.ConnectAsync($Address, $Port)
        if ($task.Wait(2500) -and $client.Connected) { return $false }
        return $true
    } catch {
        return $true
    } finally {
        $client.Dispose()
    }
}

function Get-LanIPv6InterfaceIndex([System.Net.IPAddress]$RemoteIPv4) {
    if ($RemoteIPv4.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        throw 'Remote address for LAN interface discovery must be IPv4'
    }
    # UDP Connect performs route selection locally and sends no datagram. This
    # avoids Get-NetRoute, which can require elevation on locked-down Windows.
    $socket=[Net.Sockets.Socket]::new(
        [Net.Sockets.AddressFamily]::InterNetwork,
        [Net.Sockets.SocketType]::Dgram,
        [Net.Sockets.ProtocolType]::Udp)
    try {
        $socket.Connect($RemoteIPv4,9)
        $localIPv4=[Net.IPEndPoint]$socket.LocalEndPoint
    } finally { $socket.Dispose() }
    foreach($adapter in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        $properties=$adapter.GetIPProperties()
        $match=@($properties.UnicastAddresses|Where-Object {
            $_.Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and
            $_.Address.Equals($localIPv4.Address)
        }).Count -eq 1
        if($match) {
            $ipv6Properties=$properties.GetIPv6Properties()
            if($null -eq $ipv6Properties -or $ipv6Properties.Index -le 0) {
                throw "Selected LAN adapter has no IPv6 interface index: $($adapter.Name)"
            }
            return [int]$ipv6Properties.Index
        }
    }
    throw "Could not map selected local IPv4 $($localIPv4.Address) to an interface"
}

function Format-ExceptionChain([System.Exception]$Exception) {
    $lines = [System.Collections.Generic.List[string]]::new()
    $depth = 0
    $current = $Exception
    while ($null -ne $current) {
        $lines.Add("[$depth] $($current.GetType().FullName): $($current.Message)")
        if ($current.StackTrace) { $lines.Add($current.StackTrace) }
        $current = $current.InnerException
        $depth++
    }
    return ($lines -join [Environment]::NewLine)
}

function Invoke-RemoteLoopbackHttpRequest(
    [ValidateSet("GET", "POST")][string]$Method,
    [string]$Path,
    [string]$EvidenceName,
    [AllowNull()][string]$RequestBody = $null,
    [int]$TimeoutSec = 15,
    [bool]$RequireSuccess = $true,
    [bool]$ReadOnOffAttributeEnabled = $false,
    [bool]$OnOffControlEnabled = $false,
    [bool]$CapabilityDiscoveryEnabled = $false,
    [bool]$LightStateVerificationEnabled = $false,
    [AllowNull()][string]$LightControlMode = $null,
    [bool]$TemporaryOnAllowed = $false,
    [bool]$VisualColorControl = $false,
    [int]$VisualColorRestoreLevel = -1,
    [AllowNull()]$InventoryContext=$null,
    [int]$MaxBodyBytes=1048576
) {
    if($null-ne$InventoryContext){
        Assert-MaindInventoryRequestAllowed -Context $InventoryContext -Method $Method -Path $Path -RequestBody $RequestBody
    } elseif ($LightStateVerificationEnabled) {
        Assert-MaindLightStateVerificationRequestAllowed -Method $Method -Path $Path `
            -RequestBody $RequestBody
    } elseif ($LightControlMode) {
        Assert-MaindLightControlRequestAllowed -Mode $LightControlMode `
            -Method $Method -Path $Path -RequestBody $RequestBody `
            -TemporaryOnAllowed $TemporaryOnAllowed `
            -VisualColorControl $VisualColorControl `
            -VisualColorRestoreLevel $VisualColorRestoreLevel
    } elseif ($CapabilityDiscoveryEnabled) {
        Assert-MaindCapabilityRequestAllowed -Method $Method -Path $Path `
            -RequestBody $RequestBody
    } elseif ($OnOffControlEnabled) {
        Assert-MaindOnOffControlRequestAllowed -Method $Method -Path $Path `
            -RequestBody $RequestBody
    } else {
        Assert-MaindHttpRequestAllowed `
            -Method $Method `
            -Path $Path `
            -RequestBody $RequestBody `
            -ReadOnOffAttributeEnabled $ReadOnOffAttributeEnabled
    }
    if ($null -ne $RequestBody -and $RequestBody.Contains("'")) {
        throw "Request body contains a shell-unsafe quote"
    }
    $bodyPath = Join-Path $resultDir "$EvidenceName.body"
    $stderrPath = Join-Path $resultDir "$EvidenceName.ssh_stderr.txt"
    $headersPath = Join-Path $resultDir "$EvidenceName.headers.txt"
    $statePath = Join-Path $resultDir "$EvidenceName.transport.json"
    $url = "http://127.0.0.1:8765$Path"
    $requestBodyPath = $null
    $requestBodyHash = $null
    if ($null -ne $RequestBody) {
        $requestBodyPath = Join-Path $resultDir "$EvidenceName.request.json"
        [System.IO.File]::WriteAllText($requestBodyPath, $RequestBody, [Text.UTF8Encoding]::new($false))
        $requestBodyHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $requestBodyPath).Hash.ToLowerInvariant()
    }
    # The marker separates the remote wget exit code from ssh.exe's transport
    # exit code. A valid HTTP 404 may have wget_exit_code=1 and ssh_exit_code=0.
    $wgetRequest = if ($Method -eq "POST") {
        "/usr/bin/wget -Y off -S -T $TimeoutSec -O - --header='Content-Type: application/json' --post-data='$RequestBody' '$url'"
    } else {
        "/usr/bin/wget -Y off -S -T $TimeoutSec -O - '$url'"
    }
    $remoteCommand = "$wgetRequest; wget_rc=`$?; printf '\n__MAIND_WGET_EXIT__=%s\n' `$wget_rc >&2; exit 0"

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $ssh
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($argument in @(
        "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", $SshAlias, $remoteCommand
    )) { [void]$psi.ArgumentList.Add($argument) }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    $started = [DateTime]::UtcNow
    if (-not $process.Start()) { throw "Could not start SSH remote-loopback HTTP transport" }
    try {
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $bodyStream = [System.IO.File]::Open($bodyPath, [System.IO.FileMode]::Create)
        try {
            $bodyCopyTask=$process.StandardOutput.BaseStream.CopyToAsync($bodyStream)
            $processTimeoutMs=($TimeoutSec+15)*1000
            $deadline=[DateTime]::UtcNow.AddMilliseconds($processTimeoutMs)
            while(-not$bodyCopyTask.IsCompleted){
                if($bodyStream.Length-gt$MaxBodyBytes){
                    $process.Kill($true);$process.WaitForExit()
                    throw "HTTP response exceeded per-response limit of $MaxBodyBytes bytes"
                }
                if([DateTime]::UtcNow-ge$deadline){
                    $process.Kill($true);$process.WaitForExit()
                    throw "SSH/wget request exceeded controller deadline of $processTimeoutMs ms"
                }
                Start-Sleep -Milliseconds 50
            }
            [void]$bodyCopyTask.GetAwaiter().GetResult()
            $process.WaitForExit()
            if($bodyStream.Length-gt$MaxBodyBytes){throw "HTTP response exceeded per-response limit of $MaxBodyBytes bytes"}
        } finally { $bodyStream.Dispose() }
        $completed = [DateTime]::UtcNow
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $stderr | Set-Content -Encoding UTF8 $stderrPath
        $bodyLength = (Get-Item -LiteralPath $bodyPath).Length
        $parsedEvidence = Get-MaindWgetHttpEvidence `
            -RawStderr $stderr `
            -SshExitCode $process.ExitCode `
            -BodyLength $bodyLength
        $parsedEvidence.headers | Set-Content -Encoding UTF8 $headersPath
        $bodyHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $bodyPath).Hash.ToLowerInvariant()
        $state = [ordered]@{
            started_utc = $started.ToString("o")
            completed_utc = $completed.ToString("o")
            method = $Method
            transport = "ssh_remote_command_to_station_loopback"
            proxy = "forced_off"
            url = $url
            ssh_exit_code = $process.ExitCode
            wget_exit_code = $parsedEvidence.wget_exit_code
            http_status = $parsedEvidence.http_status
            reason = $parsedEvidence.reason
            headers = @($parsedEvidence.headers)
            headers_file = [IO.Path]::GetFileName($headersPath)
            body_file = [IO.Path]::GetFileName($bodyPath)
            body_length = $bodyLength
            body_sha256 = $bodyHash
            request_body_file = if ($requestBodyPath) { [IO.Path]::GetFileName($requestBodyPath) } else { $null }
            request_body_length = if ($null -ne $RequestBody) { [Text.Encoding]::UTF8.GetByteCount($RequestBody) } else { 0 }
            request_body_sha256 = $requestBodyHash
            transport_error = $parsedEvidence.transport_error
            protocol_error = $parsedEvidence.protocol_error
            http_error = $parsedEvidence.http_error
            transfer_error = $parsedEvidence.transfer_error
            body_error = $parsedEvidence.body_error
        }
        $state | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 $statePath

        if ($RequireSuccess) {
            Assert-MaindHttpResponse -Evidence $parsedEvidence -RequireNonEmptyBody $true
        }
        return [pscustomobject]@{
            Body = [System.IO.File]::ReadAllText($bodyPath, [System.Text.Encoding]::UTF8)
            State = [pscustomobject]$state
        }
    } catch {
        Format-ExceptionChain $_.Exception |
            Set-Content -Encoding UTF8 (Join-Path $resultDir "$EvidenceName.error.txt")
        throw
    } finally { $process.Dispose() }
}

function Invoke-CapabilityAttributeRead(
    [UInt64]$ClusterId,
    [UInt64]$AttributeId,
    [string]$EvidenceName
) {
    $requestJson = Get-MaindCapabilityReadRequestJson `
        -ClusterId $ClusterId -AttributeId $AttributeId
    $response = Invoke-RemoteLoopbackHttpRequest `
        -Method 'POST' -Path '/interaction/readAttribute' `
        -EvidenceName $EvidenceName -RequestBody $requestJson `
        -TimeoutSec 30 -RequireSuccess $true `
        -CapabilityDiscoveryEnabled $true
    $attribute = Get-MaindAttributeResult -JsonText $response.Body `
        -ClusterId $ClusterId -AttributeId $AttributeId
    $attribute.parsed | ConvertTo-Json -Depth 30 | Set-Content -Encoding UTF8 `
        (Join-Path $resultDir "$EvidenceName.parsed.json")
    if (-not $attribute.supported) {
        [ordered]@{
            supported = $false
            cluster_id = $ClusterId
            attribute_id = $AttributeId
            errors = @($attribute.errors)
            interpretation = 'unsupported attribute retained as diagnostic result'
        } | ConvertTo-Json -Depth 20 | Set-Content -Encoding UTF8 `
            (Join-Path $resultDir "$EvidenceName.summary.json")
        return [pscustomobject]@{supported=$false;decoded=$null;attribute=$attribute}
    }
    $decoded = ConvertFrom-MaindMatterTlv -RawValue ([string]$attribute.value.rawValue) `
        -Root $root
    $decoded | ConvertTo-Json -Depth 50 | Set-Content -Encoding UTF8 `
        (Join-Path $resultDir "$EvidenceName.tlv.json")
    [ordered]@{
        supported = $true
        cluster_id = $ClusterId
        attribute_id = $AttributeId
        raw_value = [string]$attribute.value.rawValue
        tlv_file = "$EvidenceName.tlv.json"
    } | ConvertTo-Json | Set-Content -Encoding UTF8 `
        (Join-Path $resultDir "$EvidenceName.summary.json")
    return [pscustomobject]@{supported=$true;decoded=$decoded;attribute=$attribute}
}

function Invoke-LightAttributeRead(
    [UInt64]$ClusterId,[UInt64]$AttributeId,[string]$EvidenceName,[switch]$AllowNull
) {
    $requestJson=Get-MaindLightReadRequestJson $ClusterId $AttributeId
    $response=Invoke-RemoteLoopbackHttpRequest -Method POST -Path '/interaction/readAttribute' `
        -EvidenceName $EvidenceName -RequestBody $requestJson -TimeoutSec 30 -RequireSuccess $true `
        -LightControlMode $lightMode -TemporaryOnAllowed ([bool]$AllowTemporaryOn)
    $attribute=Get-MaindAttributeResult $response.Body $ClusterId $AttributeId
    $attribute.parsed|ConvertTo-Json -Depth 30|Set-Content -Encoding UTF8 `
        (Join-Path $resultDir "$EvidenceName.parsed.json")
    if (-not $attribute.supported) {
        return [pscustomobject]@{supported=$false;errors=$attribute.errors}
    }
    $state=Get-MaindUnsignedAttributeState $response.Body $ClusterId $AttributeId $root -AllowNull:$AllowNull
    [ordered]@{supported=$true;is_null=$state.isNull;value=$state.value;tlv_type=$state.tlvType;raw_value=$state.rawValue}|ConvertTo-Json|Set-Content -Encoding UTF8 `
        (Join-Path $resultDir "$EvidenceName.state.json")
    return $state
}

function Invoke-LightControlCommand([string]$RequestJson,[string]$EvidenceName) {
    $request=ConvertFrom-Json $RequestJson -NoEnumerate -ErrorAction Stop
    $script:lightMutationMayHaveOccurred=$true
    $response=Invoke-RemoteLoopbackHttpRequest -Method POST -Path '/interaction/invokeCommand' `
        -EvidenceName $EvidenceName -RequestBody $RequestJson -TimeoutSec 30 -RequireSuccess $true `
        -LightControlMode $lightMode -TemporaryOnAllowed ([bool]$AllowTemporaryOn) `
        -VisualColorControl $visualColorEnabled `
        -VisualColorRestoreLevel $script:visualColorRestoreLevel
    $parsed=Assert-MaindInvokeSucceeded $response.Body `
        -ExpectedEndpointId ([long]$request.endpointId) `
        -ExpectedClusterId ([long]$request.clusterId) `
        -ExpectedCommandId ([long]$request.commandId)
    $parsed|ConvertTo-Json -Depth 30|Set-Content -Encoding UTF8 `
        (Join-Path $resultDir "$EvidenceName.parsed.json")
}

function Invoke-LightOnOffRead([string]$EvidenceName) {
    $requestJson=Get-MaindLightReadRequestJson 6 0
    $response=Invoke-RemoteLoopbackHttpRequest -Method POST -Path '/interaction/readAttribute' `
        -EvidenceName $EvidenceName -RequestBody $requestJson -TimeoutSec 30 -RequireSuccess $true `
        -LightControlMode $lightMode -TemporaryOnAllowed ([bool]$AllowTemporaryOn) `
        -VisualColorControl $visualColorEnabled `
        -VisualColorRestoreLevel $script:visualColorRestoreLevel
    $attribute=Get-MaindAttributeResult $response.Body 6 0
    if (-not $attribute.supported) { throw 'OnOff attribute is required for safe control' }
    $state=Get-MaindBooleanAttributeState $response.Body 6 0 $root
    # Keep the original strict canonical check as an independent assertion.
    $canonical=[bool](Get-MaindOnOffStateFromReadResponse $response.Body)
    if ($state.value -ne $canonical) { throw 'OnOff Boolean decoders disagree' }
    [ordered]@{supported=$true;value=$state.value;tlvType=$state.tlvType;rawValue=$state.rawValue}|ConvertTo-Json|Set-Content -Encoding UTF8 `
        (Join-Path $resultDir "$EvidenceName.state.json")
    return $state
}

function Request-Rollback([string]$Reason) {
    try { Invoke-Ssh "$remoteHelperCommand rollback $Reason" } catch { Write-Warning $_ }
}

try {
    & $ssh -o BatchMode=yes -o ConnectTimeout=10 $SshAlias "true"
    if ($LASTEXITCODE -ne 0) { throw "SSH preflight failed" }

    $stagingAttempted = $true
    $localSize = Send-FileOverSshStdin $remoteScript $remotePath
    $helperUploaded = $true
    $localHash = (Get-FileHash -Algorithm SHA256 $remoteScript).Hash.ToLowerInvariant()
    $verifyCommand = @"
chmod 700 '$remotePath' || exit 1
size=`$(wc -c < '$remotePath') || exit 1
hash=`$(sha256sum '$remotePath' | awk '{print `$1}') || exit 1
[ "`$size" = '$localSize' ] || { echo "size mismatch: `$size != $localSize" >&2; exit 1; }
[ "`$hash" = '$localHash' ] || { echo "sha256 mismatch: `$hash != $localHash" >&2; exit 1; }
sh -n '$remotePath' || exit 1
printf 'size=%s\nsha256=%s\nshell_check=pass\n' "`$size" "`$hash"
"@
    $stagingEvidence = (Invoke-Ssh $verifyCommand | Out-String).Trim()
    $stagingLines = @($stagingEvidence -split "\r?\n")
    if ($stagingLines -notcontains "size=$localSize") { throw "Remote size evidence missing" }
    if ($stagingLines -notcontains "sha256=$localHash") { throw "Remote SHA-256 evidence missing" }
    if ($stagingLines -notcontains "shell_check=pass") { throw "Remote shell evidence missing" }
    $helperValidated = $true
    Write-Host "STAGING_VERIFIED`n$stagingEvidence"

    if ($StagingOnly) {
        Invoke-Ssh "rm -f '$remotePath'; [ ! -e '$remotePath' ]"
        $helperUploaded = $false
        Write-Host "STAGING_TEST_CLEANUP=PASS"
        return
    }

    # Dropbear on this station rejects direct-tcpip forwarding. Use an SSH remote
    # command to run BusyBox wget against station loopback instead. Verify the
    # required client and proxy-disable option before crossing activation.
    Invoke-Ssh "test -x /usr/bin/wget; help=`$(/usr/bin/wget --help 2>&1); printf '%s' \"`$help\" | grep -q -- '-Y'; printf '%s' \"`$help\" | grep -q -- '--header'; printf '%s' \"`$help\" | grep -q -- '--post-data'"
    [ordered]@{
        verified_utc = [DateTime]::UtcNow.ToString("o")
        transport = "ssh_remote_command_to_station_loopback"
        remote_client = "/usr/bin/wget"
        proxy = "forced_off"
        ssh_local_forwarding = "unsupported_by_dropbear_policy"
    } | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $resultDir "http_transport_preflight.json")

    $lifecycleResult=Invoke-SshCaptured "$remoteHelperCommand preflight $requiredToken"
    $lifecyclePreflight=$lifecycleResult.stdout.Trim()
    [ordered]@{exit_code=$lifecycleResult.exit_code;stdout=$lifecycleResult.stdout;stderr=$lifecycleResult.stderr;
        run_id=$runId;remote_base=$remoteBase}|ConvertTo-Json -Depth 4|Set-Content -Encoding UTF8 `
        (Join-Path $resultDir 'lifecycle_preflight.json')
    ($lifecycleResult.stdout+$lifecycleResult.stderr)|Set-Content -Encoding UTF8 `
        (Join-Path $resultDir 'lifecycle_preflight.txt')
    if($lifecycleResult.exit_code-ne0){
        $refusal=ConvertFrom-LifecycleRefusal $lifecycleResult.stdout $lifecycleResult.stderr $lifecycleResult.exit_code
        $refusal|ConvertTo-Json -Depth 4|Set-Content -Encoding UTF8 `
            (Join-Path $resultDir 'lifecycle_preflight_failure.json')
        throw "Remote lifecycle preflight refused run: code=$($refusal.code) stage=$($refusal.stage) condition=$($refusal.condition) system_changed=$($refusal.system_changed) detail=$($refusal.detail) action=$($refusal.action) exit=$($refusal.exit_code)."
    }
    if($lifecyclePreflight -notmatch "preflight=clean run_id=$([regex]::Escape($runId))"){
        throw 'Remote lifecycle preflight did not return clean ownership evidence.'
    }
    if ($lightStateVerificationEnabled) {
        $oldMarkerEvidence=(Invoke-Ssh @'
set -eu
old=/tmp/maind-http-test
for name in LIGHT_STATE_MAY_BE_CHANGED light.restore.armed light.restore.state; do
  if [ -f "$old/$name" ]; then
    size=$(wc -c < "$old/$name")
    hash=$(sha256sum "$old/$name" | awk '{print $1}')
    printf '%s|present|%s|%s\n' "$name" "$size" "$hash"
  else
    printf '%s|absent|-|-\n' "$name"
  fi
done
'@ | Out-String).Trim()
        $oldMarkerEvidence | Set-Content -Encoding UTF8 `
            (Join-Path $resultDir 'old_light_markers.before.txt')
        # A unique run directory can no longer overwrite historical markers.
        # If legacy evidence is present the lifecycle preflight blocks before
        # this point; when absent, record that fact without creating it.
        $oldMarkerEvidence|Set-Content -Encoding UTF8 `
            (Join-Path $resultDir 'old_light_markers.local_verified.txt')
    }
    $watchdogSeconds=if($inventoryEnabled){[Math]::Min(3600,$InventoryMaxSessionSeconds+180)}else{360}
    $activationCommandIssued = $true
    Invoke-Ssh "$remoteHelperCommand arm $requiredToken $watchdogSeconds"

    # A LAN path must fail before any loopback request is allowed.
    $ipv4 = [System.Net.IPAddress]::Parse($StationIPv4)
    if (-not (Test-TcpBlocked $ipv4 8765)) {
        throw "IPv4 LAN isolation failed: $StationIPv4`:8765 accepted a connection"
    }

    $lanInterfaceIndex=Get-LanIPv6InterfaceIndex ([System.Net.IPAddress]::Parse($StationIPv4))
    $ipv6 = [System.Net.IPAddress]::Parse($StationIPv6)
    $ipv6.ScopeId = $lanInterfaceIndex
    if (-not (Test-TcpBlocked $ipv6 8765)) {
        throw "IPv6 LAN isolation failed: $ipv6`:8765 accepted a connection"
    }

    # /devices is the first and only required HTTP request. The root route is
    # not a health endpoint on this firmware and is known to return HTTP 404.
    $devicesRequest = $httpRequestPlan[0]
    $devicesResponse = Invoke-RemoteLoopbackHttpRequest `
        -Method $devicesRequest.method `
        -Path $devicesRequest.path `
        -RequestBody $devicesRequest.body `
        -EvidenceName "http_devices" `
        -TimeoutSec 30 `
        -RequireSuccess $true `
        -ReadOnOffAttributeEnabled $readOnOffEnabled `
        -OnOffControlEnabled $controlEnabled `
        -CapabilityDiscoveryEnabled ($capabilityEnabled -or $vendorDiscoveryEnabled) `
        -LightStateVerificationEnabled $lightStateVerificationEnabled `
        -LightControlMode $lightMode `
        -TemporaryOnAllowed ([bool]$AllowTemporaryOn) `
        -InventoryContext $inventoryContext `
        -MaxBodyBytes $InventoryMaxResponseBytes
    $devicesBody = $devicesResponse.Body
    try {
        $devicesResult = Get-MaindDevicesJsonAnalysis -JsonText $devicesBody -TargetNodeId $InventoryTargetNodeId
        ConvertTo-Json -InputObject $devicesResult.Parsed -Depth 30 |
            Set-Content -Encoding UTF8 (Join-Path $resultDir "devices.json")
        $devicesResult.Analysis | ConvertTo-Json -Depth 30 |
            Set-Content -Encoding UTF8 (Join-Path $resultDir "devices_structure.json")
    } catch {
        $jsonError = Format-ExceptionChain $_.Exception
        $jsonError | Set-Content -Encoding UTF8 (Join-Path $resultDir "devices_json_error.txt")
        [ordered]@{
            parse_success = $false
            target_node_id = $InventoryTargetNodeId
            error = $_.Exception.Message
            raw_body_file = "http_devices.body"
        } | ConvertTo-Json -Depth 5 |
            Set-Content -Encoding UTF8 (Join-Path $resultDir "devices_structure.json")
        throw "GET /devices returned HTTP 2xx with a non-empty but invalid JSON body; see devices_json_error.txt"
    }
    if (-not $devicesResult.Analysis.target_found) {
        throw "GET /devices returned valid JSON, but target Matter Node ID $InventoryTargetNodeId was not found; see devices_structure.json"
    }
    if (-not $inventoryEnabled -and -not $devicesResult.Analysis.target_endpoint_found) {
        throw "GET /devices found Matter Node ID $InventoryTargetNodeId, but no usable endpoint was advertised; see devices_structure.json"
    }

    if($inventoryEnabled){
        $inventoryResult=Invoke-MaindFullInventory -Context $inventoryContext `
            -DevicesResult $devicesResult -ResultDirectory $resultDir -Root $root `
            -MaxRequests $InventoryMaxRequests -MaxTotalBytes $InventoryMaxTotalBytes `
            -RequestDelayMs $InventoryRequestDelayMs -MaxSessionSeconds $InventoryMaxSessionSeconds `
            -ReadAttribute {
                param($endpoint,$cluster,$attribute,$evidence)
                $request=Get-MaindInventoryReadJson -NodeId $InventoryTargetNodeId `
                    -EndpointId $endpoint -ClusterId $cluster -AttributeId $attribute
                Invoke-RemoteLoopbackHttpRequest -Method POST -Path '/interaction/readAttribute' `
                    -EvidenceName $evidence -RequestBody $request -TimeoutSec 20 -RequireSuccess $true `
                    -InventoryContext $inventoryContext -MaxBodyBytes $InventoryMaxResponseBytes
            }
        ConvertTo-Json -InputObject @($inventoryResult.errors) -Depth 20|Set-Content -Encoding UTF8 `
            (Join-Path $resultDir 'errors.json')
    } elseif ($capabilityEnabled) {
        $descriptor = Invoke-CapabilityAttributeRead `
            -ClusterId 29 -AttributeId 1 -EvidenceName 'descriptor_server_list'
        if (-not $descriptor.supported) {
            throw 'Descriptor ServerList is required for gated capability discovery'
        }
        $serverList = @(Get-MaindServerListFromTlv $descriptor.decoded)
        [ordered]@{
            endpoint_id = 1
            cluster_ids = $serverList
            contains_level_control = (8 -in $serverList)
            contains_color_control = (768 -in $serverList)
        } | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 `
            (Join-Path $resultDir 'descriptor_server_list.decoded.json')

        $discovery = [ordered]@{
            endpoint_id = 1
            server_clusters = $serverList
            level_control = [ordered]@{present=(8 -in $serverList); attributes=[ordered]@{}}
            color_control = [ordered]@{present=(768 -in $serverList); attributes=[ordered]@{}; conditional_reads=@()}
        }

        if (8 -in $serverList) {
            foreach ($spec in @(
                @{id=0;name='current_level'},
                @{id=65532;name='feature_map'},
                @{id=65529;name='accepted_command_list'}
            )) {
                $item = Invoke-CapabilityAttributeRead -ClusterId 8 `
                    -AttributeId $spec.id -EvidenceName ("level_" + $spec.name)
                $entry = [ordered]@{supported=$item.supported}
                if ($item.supported) {
                    if ($spec.id -eq 65529) {
                        $entry.value = @(Get-MaindUnsignedListFromTlv $item.decoded)
                    } else {
                        $entry.value = Get-MaindUnsignedScalarFromTlv $item.decoded
                    }
                } else { $entry.errors = @($item.attribute.errors) }
                $discovery.level_control.attributes[$spec.name] = $entry
            }
        }

        if (768 -in $serverList) {
            $colorResults = @{}
            foreach ($spec in @(
                @{id=16394;name='color_capabilities'},
                @{id=8;name='color_mode'},
                @{id=65532;name='feature_map'},
                @{id=65529;name='accepted_command_list'}
            )) {
                $item = Invoke-CapabilityAttributeRead -ClusterId 768 `
                    -AttributeId $spec.id -EvidenceName ("color_" + $spec.name)
                $colorResults[$spec.name] = $item
                $entry = [ordered]@{supported=$item.supported}
                if ($item.supported) {
                    if ($spec.id -eq 65529) {
                        $entry.value = @(Get-MaindUnsignedListFromTlv $item.decoded)
                    } else {
                        $entry.value = Get-MaindUnsignedScalarFromTlv $item.decoded
                    }
                } else { $entry.errors = @($item.attribute.errors) }
                $discovery.color_control.attributes[$spec.name] = $entry
            }

            if ($colorResults.color_capabilities.supported) {
                $capabilities = Get-MaindUnsignedScalarFromTlv `
                    $colorResults.color_capabilities.decoded
                $conditional = [Collections.Generic.List[object]]::new()
                # ColorCapabilities bit 0 is Hue/Saturation. EnhancedHue (bit
                # 1) is not treated as an independent proof for these reads.
                if (($capabilities -band 0x1) -ne 0) {
                    $conditional.Add(@{id=0;name='current_hue'})
                    $conditional.Add(@{id=1;name='current_saturation'})
                }
                if (($capabilities -band 0x8) -ne 0) {
                    $conditional.Add(@{id=3;name='current_x'})
                    $conditional.Add(@{id=4;name='current_y'})
                }
                if (($capabilities -band 0x10) -ne 0) {
                    $conditional.Add(@{id=7;name='color_temperature_mireds'})
                }
                foreach ($spec in $conditional) {
                    $item = Invoke-CapabilityAttributeRead -ClusterId 768 `
                        -AttributeId $spec.id -EvidenceName ("color_" + $spec.name)
                    $entry = [ordered]@{name=$spec.name;attribute_id=$spec.id;supported=$item.supported}
                    if ($item.supported) {
                        $entry.value = Get-MaindUnsignedScalarFromTlv $item.decoded
                    } else { $entry.errors = @($item.attribute.errors) }
                    $discovery.color_control.conditional_reads += $entry
                }
            }
        }
        $discovery | ConvertTo-Json -Depth 30 | Set-Content -Encoding UTF8 `
            (Join-Path $resultDir 'capability_discovery.json')
    } elseif ($vendorDiscoveryEnabled) {
        $vendorDescriptor=Invoke-CapabilityAttributeRead -ClusterId 29 -AttributeId 1 `
            -EvidenceName 'vendor_descriptor_server_list'
        if(-not $vendorDescriptor.supported -or
            321911814 -notin @(Get-MaindServerListFromTlv $vendorDescriptor.decoded)){
            throw 'YandexColorMusic 0x132FFC06 is absent from the current endpoint ServerList'
        }
        $vendor=[ordered]@{cluster_id=321911814;cluster_hex='0x132FFC06';attributes=[ordered]@{}}
        foreach($spec in @(
            @{id=65531;name='attribute_list';kind='list'},
            @{id=65529;name='accepted_command_list';kind='list'},
            @{id=65532;name='feature_map';kind='scalar'}
        )) {
            $item=Invoke-CapabilityAttributeRead -ClusterId 321911814 -AttributeId $spec.id `
                -EvidenceName ('yandex_color_music_'+$spec.name)
            $entry=[ordered]@{supported=$item.supported}
            if($item.supported){
                $entry.value=if($spec.kind -eq 'list'){@(Get-MaindUnsignedListFromTlv $item.decoded)}else{Get-MaindUnsignedScalarFromTlv $item.decoded}
            }else{$entry.errors=@($item.attribute.errors)}
            $vendor.attributes[$spec.name]=$entry
        }
        $vendor|ConvertTo-Json -Depth 20|Set-Content -Encoding UTF8 `
            (Join-Path $resultDir 'yandex_color_music_discovery.json')
    } elseif ($lightStateVerificationEnabled) {
        $onRequest=Get-MaindLightStateVerificationReadJson -ClusterId 6
        $onResponse=Invoke-RemoteLoopbackHttpRequest -Method POST `
            -Path '/interaction/readAttribute' -EvidenceName 'verify_current_onoff' `
            -RequestBody $onRequest -TimeoutSec 30 -RequireSuccess $true `
            -LightStateVerificationEnabled $true
        $onAttribute=Get-MaindAttributeResult $onResponse.Body 6 0
        if(-not $onAttribute.supported){throw 'OnOff is unsupported during read-only verification'}
        $actualOn=Get-MaindBooleanAttributeState $onResponse.Body 6 0 $root
        $canonicalOn=[bool](Get-MaindOnOffStateFromReadResponse $onResponse.Body)
        if([bool]$actualOn.value -ne $canonicalOn){throw 'OnOff Boolean decoders disagree'}
        $actualOn|ConvertTo-Json -Depth 10|Set-Content -Encoding UTF8 `
            (Join-Path $resultDir 'verify_current_onoff.decoded.json')

        $levelRequest=Get-MaindLightStateVerificationReadJson -ClusterId 8
        $levelResponse=Invoke-RemoteLoopbackHttpRequest -Method POST `
            -Path '/interaction/readAttribute' -EvidenceName 'verify_current_level' `
            -RequestBody $levelRequest -TimeoutSec 30 -RequireSuccess $true `
            -LightStateVerificationEnabled $true
        $levelAttribute=Get-MaindAttributeResult $levelResponse.Body 8 0
        if(-not $levelAttribute.supported){throw 'CurrentLevel is unsupported during read-only verification'}
        $actualLevel=Get-MaindUnsignedAttributeState $levelResponse.Body 8 0 $root
        if($actualLevel.isNull){throw 'CurrentLevel is null during read-only verification'}
        $actualLevel|ConvertTo-Json -Depth 10|Set-Content -Encoding UTF8 `
            (Join-Path $resultDir 'verify_current_level.decoded.json')

        $verification=Compare-MaindLightStateWithExpected `
            -ActualOnOff ([bool]$actualOn.value) -ActualLevel ([UInt64]$actualLevel.value) `
            -ExpectedOnOff $false -ExpectedLevel 4
        $verification|ConvertTo-Json -Depth 10|Set-Content -Encoding UTF8 `
            (Join-Path $resultDir 'light_state_verification.json')
        $verificationStatus=if($verification.light_state_verified){'YES'}else{'NO'}
        Set-Content -LiteralPath (Join-Path $resultDir 'LIGHT_STATE_VERIFIED.txt') `
            -Value $verificationStatus -Encoding ascii
        # A mismatch is an observation, not an error and never authorizes a
        # command. Lifecycle rollback still runs below.
    } elseif ($lightControlEnabled) {
        $initialOnOff=Invoke-LightOnOffRead 'light_initial_onoff'
        $initialLevel=Invoke-LightAttributeRead 8 0 'light_initial_level'
        if(-not $initialLevel.supported){throw 'CurrentLevel is required for safe restoration'}
        $snapshot=[ordered]@{mode=$lightMode;onoff=$initialOnOff;level=$initialLevel}
        $lightInitialOnOff=$initialOnOff
        $lightInitialLevel=$initialLevel

        if($brightnessEnabled){
            $snapshot.recovery_attributes=[ordered]@{}
            foreach($spec in @(
                @{id=15;name='options';nullable=$false},
                @{id=16;name='on_off_transition_time';nullable=$false},
                @{id=17;name='on_level';nullable=$true}
            )){
                $item=Invoke-LightAttributeRead 8 $spec.id ('brightness_initial_'+$spec.name) -AllowNull:$spec.nullable
                $snapshot.recovery_attributes[$spec.name]=$item
            }
            $snapshot.color_diagnostic=[ordered]@{}
            foreach($spec in @(
                @{id=8;name='mode'},@{id=0;name='hue'},@{id=1;name='saturation'},
                @{id=3;name='x'},@{id=4;name='y'},@{id=7;name='temperature'}
            )){
                $item=Invoke-LightAttributeRead 768 $spec.id ('brightness_initial_color_'+$spec.name)
                if(-not $item.supported){throw "Color safety attribute $($spec.name) is required before brightness control"}
                $snapshot.color_diagnostic[$spec.name]=$item
            }
            if([UInt64]$snapshot.color_diagnostic.mode.value -notin @(0,1,2)){
                throw 'Brightness test supports safety verification only for ColorMode HS, XY, or ColorTemperature'
            }
        }else{
            $snapshot.color=[ordered]@{}
            foreach($spec in @(
                @{id=8;name='mode'},@{id=0;name='hue'},@{id=1;name='saturation'},
                @{id=3;name='x'},@{id=4;name='y'},@{id=7;name='temperature'}
            )){
                $item=Invoke-LightAttributeRead 768 $spec.id ('color_initial_'+$spec.name)
                if(-not $item.supported){throw "Color attribute $($spec.name) is required for snapshot"}
                $snapshot.color[$spec.name]=$item
            }
            if([UInt64]$snapshot.color.mode.value -ne 0){
                throw 'First color experiment is restricted to initial ColorMode 0 (Hue/Saturation)'
            }
        }
        $snapshot|ConvertTo-Json -Depth 20|Set-Content -Encoding UTF8 (Join-Path $resultDir 'light_initial_snapshot.json')
        if($visualColorEnabled){$script:visualColorRestoreLevel=[int]$initialLevel.value}
        $visualTarget=$null
        if($visualBrightnessEnabled){
            $visualTarget=Get-MaindVisualBrightnessTarget -CurrentLevel ([int]$initialLevel.value) `
                -TargetLevel 64 -MinimumDifference 16
        }
        if(-not $initialOnOff.value -and -not $AllowTemporaryOn){
            throw 'Lamp is Off; no state change made. Separate temporary-On approval is required.'
        }

        $onInt=if($initialOnOff.value){1}else{0}
        if($brightnessEnabled){
            Invoke-Ssh "$remoteHelperCommand light-restore-arm I_APPROVE_LIGHT_STATE_RESTORE brightness $onInt $($initialOnOff.rawValue) $($initialLevel.value) $($initialLevel.rawValue) - - - - - -"
        }else{
            Invoke-Ssh "$remoteHelperCommand light-restore-arm I_APPROVE_LIGHT_STATE_RESTORE color $onInt $($initialOnOff.rawValue) $($initialLevel.value) $($initialLevel.rawValue) $($snapshot.color.mode.value) $($snapshot.color.mode.rawValue) $($snapshot.color.hue.value) $($snapshot.color.hue.rawValue) $($snapshot.color.saturation.value) $($snapshot.color.saturation.rawValue)"
        }

        if(-not $initialOnOff.value){
            Invoke-LightControlCommand (Get-MaindOnOffInvokeRequestJson 1) 'light_temporary_on'
            Start-Sleep -Seconds 1
            if(-not (Invoke-LightOnOffRead 'light_temporary_on_verify').value){throw 'Temporary On verification failed'}
        }

        if($brightnessEnabled){
            $target=if($visualBrightnessEnabled){$visualTarget}else{Get-SmallChangedValue -Value ([int]$initialLevel.value) -Maximum 254 -Minimum 1 -Delta 4}
            $requestedHoldSeconds=if($visualBrightnessEnabled){3}else{0}
            $brightnessTiming=[ordered]@{
                baseline_captured_utc=[DateTime]::UtcNow.ToString('o')
                target_level=$target
                requested_hold_seconds=$requestedHoldSeconds
            }
            $brightnessTiming.change_command_started_utc=[DateTime]::UtcNow.ToString('o')
            Invoke-LightControlCommand (Get-MaindMoveToLevelRequestJson $target 5) 'brightness_change'
            Start-Sleep -Seconds 2
            $changed=Invoke-LightAttributeRead 8 0 'brightness_changed_level'
            if([UInt64]$changed.value -ne $target){throw 'Brightness change readback mismatch'}
            $brightnessTiming.change_confirmed_utc=[DateTime]::UtcNow.ToString('o')
            if($visualBrightnessEnabled){
                $hold=Invoke-MaindBrightnessHold -Seconds 3
                $brightnessTiming.hold_started_utc=$hold.started_utc
                $brightnessTiming.hold_completed_utc=$hold.completed_utc
                $brightnessTiming.hold_elapsed_ms=$hold.elapsed_ms
            }
            $brightnessTiming.restore_command_started_utc=[DateTime]::UtcNow.ToString('o')
            Invoke-LightControlCommand (Get-MaindMoveToLevelRequestJson ([int]$initialLevel.value) 5) 'brightness_restore'
            Start-Sleep -Seconds 2
            $restored=Invoke-LightAttributeRead 8 0 'brightness_restored_level'
            if([UInt64]$restored.value -ne [UInt64]$initialLevel.value){throw 'Brightness restoration readback mismatch'}
            $brightnessTiming.restore_confirmed_utc=[DateTime]::UtcNow.ToString('o')
            $brightnessTiming|ConvertTo-Json -Depth 5|Set-Content -Encoding UTF8 `
                (Join-Path $resultDir 'brightness_timing.json')
            $finalColor=[ordered]@{}
            foreach($spec in @(
                @{id=8;name='mode'},@{id=0;name='hue'},@{id=1;name='saturation'},
                @{id=3;name='x'},@{id=4;name='y'},@{id=7;name='temperature'}
            )){
                $finalColor[$spec.name]=Invoke-LightAttributeRead 768 $spec.id ('brightness_final_color_'+$spec.name)
            }
            Assert-MaindActiveColorStateUnchanged $snapshot.color_diagnostic $finalColor
        }else{
            $targetHue=if($visualColorEnabled){
                Get-MaindVisualColorHueTarget -CurrentHue ([int]$snapshot.color.hue.value) -Delta 85
            }else{
                Get-SmallChangedValue -Value ([int]$snapshot.color.hue.value) -Maximum 254 -Minimum 0 -Delta 4
            }
            $sat=[int]$snapshot.color.saturation.value
            $colorTiming=[ordered]@{
                baseline_captured_utc=[DateTime]::UtcNow.ToString('o')
                visual_color_test=$visualColorEnabled
                baseline_level=[int]$initialLevel.value
                target_level=if($visualColorEnabled){64}else{[int]$initialLevel.value}
                baseline_hue=[int]$snapshot.color.hue.value
                target_hue=$targetHue
                saturation=$sat
                requested_hold_seconds=if($visualColorEnabled){3}else{0}
            }
            if($visualColorEnabled){
                $colorTiming.level_change_started_utc=[DateTime]::UtcNow.ToString('o')
                Invoke-LightControlCommand (Get-MaindMoveToLevelRequestJson 64 5) 'visual_color_level_change'
                Start-Sleep -Seconds 2
                $visualLevel=Invoke-LightAttributeRead 8 0 'visual_color_changed_level'
                if([UInt64]$visualLevel.value -ne 64){throw 'Visual color brightness readback mismatch'}
                $colorTiming.level_change_confirmed_utc=[DateTime]::UtcNow.ToString('o')
            }
            $colorTiming.color_change_started_utc=[DateTime]::UtcNow.ToString('o')
            Invoke-LightControlCommand (Get-MaindMoveToHueAndSaturationRequestJson $targetHue $sat 5) 'color_change'
            Start-Sleep -Seconds 2
            $changedMode=Invoke-LightAttributeRead 768 8 'color_changed_mode'
            $changedHue=Invoke-LightAttributeRead 768 0 'color_changed_hue'
            $changedSat=Invoke-LightAttributeRead 768 1 'color_changed_saturation'
            if([UInt64]$changedMode.value -ne 0 -or [UInt64]$changedHue.value -ne $targetHue -or
                [UInt64]$changedSat.value -ne $sat){throw 'Color change readback mismatch'}
            if($visualColorEnabled){
                $confirmedLevel=Invoke-LightAttributeRead 8 0 'visual_color_confirmed_level'
                if([UInt64]$confirmedLevel.value -ne 64){throw 'Visual color level changed before hold'}
            }
            $colorTiming.color_change_confirmed_utc=[DateTime]::UtcNow.ToString('o')
            if($visualColorEnabled){
                $hold=Invoke-MaindBrightnessHold -Seconds 3
                $colorTiming.hold_started_utc=$hold.started_utc
                $colorTiming.hold_completed_utc=$hold.completed_utc
                $colorTiming.hold_elapsed_ms=$hold.elapsed_ms
            }
            $colorTiming.color_restore_started_utc=[DateTime]::UtcNow.ToString('o')
            Invoke-LightControlCommand (Get-MaindMoveToHueAndSaturationRequestJson `
                ([int]$snapshot.color.hue.value) $sat 5) 'color_restore'
            Start-Sleep -Seconds 2
            $restoredMode=Invoke-LightAttributeRead 768 8 'color_restored_mode'
            $restoredHue=Invoke-LightAttributeRead 768 0 'color_restored_hue'
            $restoredSat=Invoke-LightAttributeRead 768 1 'color_restored_saturation'
            if([UInt64]$restoredMode.value -ne 0 -or
                [UInt64]$restoredHue.value -ne [UInt64]$snapshot.color.hue.value -or
                [UInt64]$restoredSat.value -ne [UInt64]$snapshot.color.saturation.value){
                throw 'Color restoration readback mismatch'
            }
            $colorTiming.color_restore_confirmed_utc=[DateTime]::UtcNow.ToString('o')
            if($visualColorEnabled){
                $colorTiming.level_restore_started_utc=[DateTime]::UtcNow.ToString('o')
                Invoke-LightControlCommand (Get-MaindMoveToLevelRequestJson ([int]$initialLevel.value) 5) 'visual_color_level_restore'
                Start-Sleep -Seconds 2
                $restoredLevel=Invoke-LightAttributeRead 8 0 'visual_color_restored_level'
                if([UInt64]$restoredLevel.value -ne [UInt64]$initialLevel.value){
                    throw 'Visual color level restoration readback mismatch'
                }
                $colorTiming.level_restore_confirmed_utc=[DateTime]::UtcNow.ToString('o')
            }
            # Inactive representations are diagnostic only. A HS command may
            # legitimately update derived XY/CT values, so do not claim that
            # byte equality here proves or disproves active-mode restoration.
            [void](Invoke-LightAttributeRead 768 3 'color_final_x_diagnostic')
            [void](Invoke-LightAttributeRead 768 4 'color_final_y_diagnostic')
            [void](Invoke-LightAttributeRead 768 7 'color_final_temperature_diagnostic')
        }

        $finalLevel=Invoke-LightAttributeRead 8 0 'light_final_level'
        if([UInt64]$finalLevel.value -ne [UInt64]$initialLevel.value){throw 'Final level differs from initial'}
        if($colorEnabled){$colorTiming.final_level_confirmed_utc=[DateTime]::UtcNow.ToString('o')}
        if(-not $initialOnOff.value){
            if($colorEnabled){$colorTiming.onoff_restore_started_utc=[DateTime]::UtcNow.ToString('o')}
            Invoke-LightControlCommand (Get-MaindOnOffInvokeRequestJson 0) 'light_restore_off'
            Start-Sleep -Seconds 1
        }
        $finalOnOff=Invoke-LightOnOffRead 'light_final_onoff'
        if($finalOnOff.value -ne $initialOnOff.value){throw 'Final OnOff differs from initial'}
        if($colorEnabled){
            $colorTiming.onoff_restore_confirmed_utc=[DateTime]::UtcNow.ToString('o')
            $colorTiming.all_restoration_confirmed_utc=[DateTime]::UtcNow.ToString('o')
            $colorTiming|ConvertTo-Json -Depth 6|Set-Content -Encoding UTF8 `
                (Join-Path $resultDir 'color_visual_timing.json')
        }
        Invoke-Ssh "$remoteHelperCommand light-restore-clear I_CONFIRM_LIGHT_RESTORE_READBACK $($initialOnOff.rawValue) $($initialLevel.rawValue)"
        $reportedTestLevel=if($brightnessEnabled){$target}elseif($visualColorEnabled){64}else{$null}
        [ordered]@{mode=$lightMode;visual_brightness_test=$visualBrightnessEnabled;
            visual_color_test=$visualColorEnabled;
            restoration_verified=$true;initial_onoff=$initialOnOff.value;
            initial_level=$initialLevel.value;test_level=$reportedTestLevel;
            test_hue=if($colorEnabled){$targetHue}else{$null};
            temporary_on_used=(-not $initialOnOff.value)}|ConvertTo-Json|Set-Content -Encoding UTF8 `
            (Join-Path $resultDir 'light_control_result.json')
    } elseif ($readOnOffEnabled) {
        # Exact schema recovered from the installed Matter HTTP index.html and
        # emitted by the shared request plan used by integration tests.
        $readPlanEntry = $httpRequestPlan[1]
        $readRequestJson = $readPlanEntry.body
        $readRequest = ConvertFrom-Json -InputObject $readRequestJson -NoEnumerate
        $readResponse = Invoke-RemoteLoopbackHttpRequest `
            -Method $readPlanEntry.method `
            -Path $readPlanEntry.path `
            -EvidenceName "http_read_onoff" `
            -RequestBody $readRequestJson `
            -TimeoutSec 30 `
            -RequireSuccess $true `
            -ReadOnOffAttributeEnabled $readOnOffEnabled `
            -OnOffControlEnabled $controlEnabled
        try {
            $readParsed = ConvertFrom-Json `
                -InputObject $readResponse.Body `
                -Depth 30 `
                -NoEnumerate `
                -ErrorAction Stop
            ConvertTo-Json -InputObject $readParsed -Depth 30 |
                Set-Content -Encoding UTF8 (Join-Path $resultDir "read_onoff.parsed.json")
            $readPaths = @(Get-MaindJsonPathInventory $readParsed)
            $readPaths | ConvertTo-Json -Depth 10 |
                Set-Content -Encoding UTF8 (Join-Path $resultDir "read_onoff_json_paths.json")
            [ordered]@{
                parse_success = $true
                request = $readRequest
                root_kind = Get-MaindJsonKind $readParsed
                leaf_count = $readPaths.Count
                interpretation = "raw Matter HTTP response retained; no response shape assumed"
            } | ConvertTo-Json -Depth 10 |
                Set-Content -Encoding UTF8 (Join-Path $resultDir "read_onoff_summary.json")
        } catch {
            Format-ExceptionChain $_.Exception |
                Set-Content -Encoding UTF8 (Join-Path $resultDir "read_onoff_json_error.txt")
            [ordered]@{
                parse_success = $false
                request = $readRequest
                raw_body_file = "http_read_onoff.body"
                error = $_.Exception.Message
            } | ConvertTo-Json -Depth 10 |
                Set-Content -Encoding UTF8 (Join-Path $resultDir "read_onoff_summary.json")
            throw "OnOff read returned HTTP 2xx with invalid JSON; no fallback request will be attempted"
        }
        $readAttribute=Get-MaindAttributeResult $readResponse.Body 6 0
        if(-not $readAttribute.supported){throw 'Matter OnOff read returned errors'}
        $readOnOffState=Get-MaindBooleanAttributeState $readResponse.Body 6 0 $root
        $canonicalReadOnOff=[bool](Get-MaindOnOffStateFromReadResponse $readResponse.Body)
        if([bool]$readOnOffState.value -ne $canonicalReadOnOff){throw 'OnOff Boolean decoders disagree'}
        $readOnOffState|ConvertTo-Json -Depth 10|Set-Content -Encoding UTF8 `
            (Join-Path $resultDir 'read_onoff.decoded.json')
        if ($controlEnabled) {
            $originalOnOffState = $canonicalReadOnOff
            [ordered]@{
                original_state = [bool]$originalOnOffState
                raw_body_file = 'http_read_onoff.body'
                interpretation = 'canonical Matter TLV Boolean only'
            } | ConvertTo-Json | Set-Content -Encoding UTF8 `
                (Join-Path $resultDir 'control_original_state.json')
        }

        if ($controlEnabled) {
            $originalStateInt = if ([bool]$originalOnOffState) { 1 } else { 0 }
            Invoke-Ssh "$remoteHelperCommand control-restore-arm $ControlConfirmToken $originalStateInt"
            $targetState = -not [bool]$originalOnOffState
            $changeCommandId = Get-MaindOnOffCommandIdForState $targetState
            $changeBody = Get-MaindOnOffInvokeRequestJson -CommandId $changeCommandId
            # Set before transport: a command may reach Matter even if its HTTP
            # response is lost, so every later failure must attempt restoration.
            $changeCommandAttempted = $true
            $changeResponse = Invoke-RemoteLoopbackHttpRequest `
                -Method 'POST' -Path '/interaction/invokeCommand' `
                -EvidenceName 'http_invoke_change' -RequestBody $changeBody `
                -TimeoutSec 30 -RequireSuccess $true `
                -ReadOnOffAttributeEnabled $true -OnOffControlEnabled $true
            try {
                $changeParsed = Assert-MaindInvokeSucceeded $changeResponse.Body `
                    -ExpectedEndpointId 1 -ExpectedClusterId 6 -ExpectedCommandId $changeCommandId
                $changeParsed | ConvertTo-Json -Depth 30 | Set-Content -Encoding UTF8 `
                    (Join-Path $resultDir 'invoke_change.parsed.json')
            } catch {
                throw "OnOff change returned non-JSON response; restoration is required"
            }

            $afterChangeRead = Invoke-RemoteLoopbackHttpRequest `
                -Method 'POST' -Path '/interaction/readAttribute' `
                -EvidenceName 'http_read_after_change' `
                -RequestBody (Get-MaindOnOffReadRequestJson) `
                -TimeoutSec 30 -RequireSuccess $true `
                -ReadOnOffAttributeEnabled $true -OnOffControlEnabled $true
            $afterChangeState = Get-MaindOnOffStateFromReadResponse $afterChangeRead.Body
            if ([bool]$afterChangeState -ne $targetState) {
                throw "Post-change OnOff read did not match the requested state"
            }

            $restoreCommandId = Get-MaindOnOffCommandIdForState ([bool]$originalOnOffState)
            $restoreBody = Get-MaindOnOffInvokeRequestJson -CommandId $restoreCommandId
            $restoreResponse=Invoke-RemoteLoopbackHttpRequest `
                -Method 'POST' -Path '/interaction/invokeCommand' `
                -EvidenceName 'http_invoke_restore' -RequestBody $restoreBody `
                -TimeoutSec 30 -RequireSuccess $true `
                -ReadOnOffAttributeEnabled $true -OnOffControlEnabled $true
            [void](Assert-MaindInvokeSucceeded $restoreResponse.Body `
                -ExpectedEndpointId 1 -ExpectedClusterId 6 -ExpectedCommandId $restoreCommandId)
            $afterRestoreRead = Invoke-RemoteLoopbackHttpRequest `
                -Method 'POST' -Path '/interaction/readAttribute' `
                -EvidenceName 'http_read_after_restore' `
                -RequestBody (Get-MaindOnOffReadRequestJson) `
                -TimeoutSec 30 -RequireSuccess $true `
                -ReadOnOffAttributeEnabled $true -OnOffControlEnabled $true
            $afterRestoreState = Get-MaindOnOffStateFromReadResponse $afterRestoreRead.Body
            if ([bool]$afterRestoreState -ne [bool]$originalOnOffState) {
                throw "Restoration verification failed: lamp may remain changed"
            }
            $restorationVerified = $true
            Invoke-Ssh "$remoteHelperCommand control-restore-clear"
            [ordered]@{
                original_state = [bool]$originalOnOffState
                changed_state = $targetState
                change_command_id = $changeCommandId
                restore_command_id = $restoreCommandId
                restoration_verified = $true
            } | ConvertTo-Json | Set-Content -Encoding UTF8 `
                (Join-Path $resultDir 'control_state_transition.json')
        }
    } else {
        "readAttribute intentionally deferred; rerun only with -ReadOnOffAttribute after explicit approval." |
            Set-Content -Encoding UTF8 (Join-Path $resultDir "read_attribute_deferred.txt")
    }

    $completionReason = if($inventoryEnabled){
        'completed_read_only_full_inventory'
    } elseif ($controlEnabled) {
        'completed_control_change_and_verified_restore'
    } elseif ($lightControlEnabled) {
        "completed_${lightMode}_change_and_verified_restore"
    } elseif ($capabilityEnabled) {
        'completed_read_only_capability_discovery'
    } elseif ($vendorDiscoveryEnabled) {
        'completed_read_only_yandex_color_music_discovery'
    } elseif ($lightStateVerificationEnabled) {
        'completed_read_only_light_state_verification'
    } else {
        'completed_read_only_checks'
    }
    Invoke-Ssh "$remoteHelperCommand rollback $completionReason"
    Invoke-Ssh "$remoteHelperCommand verify-clean"
    $finalStatus=(Invoke-Ssh "$remoteHelperCommand status"|Out-String)
    $finalStatus|Set-Content -Encoding UTF8 (Join-Path $resultDir "final_status.txt")
    if($inventoryEnabled){
        [ordered]@{verified_clean=($finalStatus-match'completed=yes'-and$finalStatus-match'guard4=no'-and$finalStatus-match'guard6=no'-and$finalStatus-match'patch_mount=no');raw_status_file='final_status.txt';completed_utc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content -Encoding UTF8 (Join-Path $resultDir 'postflight.json')
    }
    if($lightStateVerificationEnabled){
        $oldMarkerAfter=(Invoke-Ssh @'
set -eu
old=/tmp/maind-http-test
for name in LIGHT_STATE_MAY_BE_CHANGED light.restore.armed light.restore.state; do
  if [ -f "$old/$name" ]; then
    size=$(wc -c < "$old/$name")
    hash=$(sha256sum "$old/$name" | awk '{print $1}')
    printf '%s|present|%s|%s\n' "$name" "$size" "$hash"
  else
    printf '%s|absent|-|-\n' "$name"
  fi
done
'@ | Out-String).Trim()
        $oldMarkerAfter|Set-Content -Encoding UTF8 `
            (Join-Path $resultDir 'old_light_markers.after.txt')
        if($oldMarkerAfter -cne $oldMarkerEvidence){
            throw 'Historical light-state marker hashes changed during read-only verification.'
        }
        [ordered]@{unchanged=$true;markers_retained=$true}|ConvertTo-Json|Set-Content -Encoding UTF8 `
            (Join-Path $resultDir 'old_light_markers.verification.json')
    }
} catch {
    $controllerError = Format-ExceptionChain $_.Exception
    $controllerError | Set-Content -Encoding UTF8 (Join-Path $resultDir "controller_error.txt")
    if ($brightnessEnabled -and $lightMutationMayHaveOccurred -and
        -not $restorationVerified -and $null -ne $lightInitialOnOff -and
        $null -ne $lightInitialLevel -and $activationCommandIssued -and $helperValidated) {
        try {
            $emergencyResult=Invoke-MaindBrightnessEmergencyRestore `
                -OriginalOnOff ([bool]$lightInitialOnOff.value) `
                -OriginalLevel ([int]$lightInitialLevel.value) `
                -InvokeCommand { param($json,$name) Invoke-LightControlCommand $json $name } `
                -ReadLevel { param($name) Invoke-LightAttributeRead 8 0 $name } `
                -ReadOnOff { param($name) Invoke-LightOnOffRead $name }
            $restorationVerified=$true
            Invoke-Ssh "$remoteHelperCommand light-restore-clear I_CONFIRM_LIGHT_RESTORE_READBACK $($lightInitialOnOff.rawValue) $($lightInitialLevel.rawValue)"
            $emergencyResult|ConvertTo-Json|Set-Content -Encoding UTF8 `
                (Join-Path $resultDir 'light_emergency_restore.json')
        } catch {
            [ordered]@{restoration_verified=$false;possible_lamp_state_changed=$true;
                mode=$lightMode;error=(Format-ExceptionChain $_.Exception)}|ConvertTo-Json -Depth 8|Set-Content -Encoding UTF8 `
                (Join-Path $resultDir 'LIGHT_STATE_MAY_BE_CHANGED.json')
            Write-Warning 'Emergency light restoration could not be verified before API rollback.'
        }
    }
    if ($controlEnabled -and $changeCommandAttempted -and
        -not $restorationVerified -and $null -ne $originalOnOffState -and
        $activationCommandIssued -and $helperValidated) {
        try {
            $emergencyCommandId = Get-MaindOnOffCommandIdForState ([bool]$originalOnOffState)
            $emergencyBody = Get-MaindOnOffInvokeRequestJson -CommandId $emergencyCommandId
            $emergencyResponse=Invoke-RemoteLoopbackHttpRequest `
                -Method 'POST' -Path '/interaction/invokeCommand' `
                -EvidenceName 'http_invoke_emergency_restore' `
                -RequestBody $emergencyBody -TimeoutSec 30 -RequireSuccess $true `
                -ReadOnOffAttributeEnabled $true -OnOffControlEnabled $true
            [void](Assert-MaindInvokeSucceeded $emergencyResponse.Body `
                -ExpectedEndpointId 1 -ExpectedClusterId 6 -ExpectedCommandId $emergencyCommandId)
            $emergencyRead = Invoke-RemoteLoopbackHttpRequest `
                -Method 'POST' -Path '/interaction/readAttribute' `
                -EvidenceName 'http_read_emergency_restore' `
                -RequestBody (Get-MaindOnOffReadRequestJson) `
                -TimeoutSec 30 -RequireSuccess $true `
                -ReadOnOffAttributeEnabled $true -OnOffControlEnabled $true
            $emergencyState = Get-MaindOnOffStateFromReadResponse $emergencyRead.Body
            if ([bool]$emergencyState -ne [bool]$originalOnOffState) {
                throw 'Emergency restoration readback mismatch'
            }
            $restorationVerified = $true
            Invoke-Ssh "$remoteHelperCommand control-restore-clear"
            [ordered]@{
                restoration_verified = $true
                method = 'emergency_restore_before_api_rollback'
                original_state = [bool]$originalOnOffState
            } | ConvertTo-Json | Set-Content -Encoding UTF8 `
                (Join-Path $resultDir 'control_emergency_restore.json')
        } catch {
            [ordered]@{
                restoration_verified = $false
                possible_lamp_state_changed = $true
                original_state = [bool]$originalOnOffState
                error = (Format-ExceptionChain $_.Exception)
            } | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 `
                (Join-Path $resultDir 'CONTROL_STATE_MAY_BE_CHANGED.json')
            Write-Warning 'OnOff restoration could not be verified; lamp state may remain changed.'
        }
    }
    if ($activationCommandIssued -and $helperValidated) {
        try {
            (Invoke-Ssh "$remoteHelperCommand http-diagnostics controller_error" | Out-String) |
                Set-Content -Encoding UTF8 (Join-Path $resultDir "remote_http_diagnostics_command.txt")
        } catch {
            (Format-ExceptionChain $_.Exception) |
                Set-Content -Encoding UTF8 (Join-Path $resultDir "remote_http_diagnostics_command.error.txt")
        }
    }
    if ($activationCommandIssued -and $helperValidated) {
        # The helper's activation.started marker prevents a platformd lifecycle
        # when arm() failed before the activation boundary.
        Request-Rollback "controller_error"
        if ($lightControlEnabled) {
            try {
                & $ssh -o BatchMode=yes $SshAlias `
                    "test ! -f '$remoteBase/LIGHT_STATE_MAY_BE_CHANGED'"
                if ($LASTEXITCODE -ne 0) {
                    [ordered]@{restoration_verified=$false;possible_lamp_state_changed=$true;
                        mode=$lightMode}|ConvertTo-Json|Set-Content -Encoding UTF8 `
                        (Join-Path $resultDir 'LIGHT_STATE_MAY_BE_CHANGED.json')
                    Write-Warning 'Light restoration was not verified; lamp state may remain changed.'
                }
            } catch { Write-Warning 'Could not determine light restoration marker after rollback.' }
        }
    } elseif ($stagingAttempted) {
        # No validated helper exists: remove only the temporary staging path.
        Remove-PartialStaging
        $helperUploaded = $false
    }
    throw
} finally {
    if (-not $StagingOnly -and $activationCommandIssued) {
        try {
            Receive-DirectoryOverSshTar $remoteBase $resultDir
        } catch {
            Write-Warning "Could not retrieve remote runtime logs: $_"
        }
    }
}

Write-Host "Controlled test completed and rollback requested. Results: $resultDir"
