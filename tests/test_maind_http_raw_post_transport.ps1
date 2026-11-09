[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\maind_http_response_helpers.ps1')

function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw $Message}}

$body='{"nodeId":259,"label":"Aé"}'
$request=New-MaindRawHttpPostRequest -Path '/interaction/readAttribute' -Body $body
$expectedLength=[Text.UTF8Encoding]::new($false).GetByteCount($body)
Assert-True ($request.StartsWith("POST /interaction/readAttribute HTTP/1.1`r`n")) 'request line mismatch'
Assert-True ($request.Contains("Host: 127.0.0.1:8765`r`n")) 'Host header missing'
Assert-True ($request.Contains("Content-Type: application/json`r`n")) 'Content-Type missing'
Assert-True ($request.Contains("Content-Length: $expectedLength`r`n")) 'UTF-8 Content-Length mismatch'
Assert-True ($request.Contains("Connection: close`r`n`r`n$body")) 'Connection close or body boundary missing'

$responseBody='{"ok":true}'
$response="HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $([Text.Encoding]::UTF8.GetByteCount($responseBody))`r`nConnection: close`r`n`r`n$responseBody"
$parsed=ConvertFrom-MaindRawHttpResponse -RawResponse $response -RawStderr "__MAIND_TELNET_EXIT__=0`n" -SshExitCode 0
Assert-MaindHttpResponse -Evidence $parsed -RequireNonEmptyBody $true
Assert-True ($parsed.body-ceq$responseBody) 'response body mismatch'
Assert-True ($parsed.http_status-eq200) 'response status mismatch'
$nativeParsed=ConvertFrom-MaindRawHttpResponse -RawResponse $response `
    -RawStderr "__MAIND_NATIVE_EXIT__=0`n" -SshExitCode 0 -TransportKind native
Assert-MaindHttpResponse -Evidence $nativeParsed -RequireNonEmptyBody $true
Assert-True ($nativeParsed.transport-ceq'maind_http_local_native_http_1_1') 'native transport label mismatch'

foreach($case in @(
    @{name='missing_marker';raw=$response;stderr='';ssh=0;kind='transport_error'},
    @{name='ssh_loss';raw='';stderr='';ssh=255;kind='transport_error'},
    @{name='telnet_failure';raw='';stderr="__MAIND_TELNET_EXIT__=143`n";ssh=0;kind='transfer_error'},
    @{name='missing_content_length';raw="HTTP/1.1 200 OK`r`nConnection: close`r`n`r`n{}";stderr="__MAIND_TELNET_EXIT__=0`n";ssh=0;kind='protocol_error'},
    @{name='length_mismatch';raw="HTTP/1.1 200 OK`r`nContent-Length: 9`r`n`r`n{}";stderr="__MAIND_TELNET_EXIT__=0`n";ssh=0;kind='protocol_error'},
    @{name='chunked_rejected';raw="HTTP/1.1 200 OK`r`nTransfer-Encoding: chunked`r`nContent-Length: 2`r`n`r`n{}";stderr="__MAIND_TELNET_EXIT__=0`n";ssh=0;kind='protocol_error'},
    @{name='http_500';raw="HTTP/1.1 500 Failed`r`nContent-Length: 2`r`n`r`n{}";stderr="__MAIND_TELNET_EXIT__=0`n";ssh=0;kind='http_error'}
)){
    $e=ConvertFrom-MaindRawHttpResponse -RawResponse $case.raw -RawStderr $case.stderr -SshExitCode $case.ssh
    Assert-True ($null-ne$e.($case.kind)) "$($case.name) was not classified as $($case.kind)"
}

$runtime=Get-Content -Raw -LiteralPath (Join-Path $root 'scripts\start_maind_http_runtime_test.ps1')
Assert-True ($runtime.Contains('/bin/busybox telnet 127.0.0.1 8765')) 'production telnet transport missing'
Assert-True ($runtime.Contains('/bin/busybox setsid')) 'remote process-group isolation missing'
Assert-True ($runtime.Contains('__MAIND_TELNET_EXIT__')) 'transport completion marker missing'
Assert-True ($runtime.Contains("/tmp/maind-http-local.`$runId")) 'run-scoped native client path missing'
Assert-True ($runtime.Contains('__MAIND_NATIVE_EXIT__')) 'native completion marker missing'
Assert-True ($runtime.Contains("fixed_destination='127.0.0.1:8765'")) 'native loopback restriction evidence missing'
Assert-True ($runtime.Contains('Claim-MaindEcmWindowPost')) 'one-shot claim missing'
$secure=$runtime.Substring($runtime.IndexOf('function Invoke-MaindEcmWindowPostSecure'),$runtime.IndexOf('function Close-MatterWebSocketBounded')-$runtime.IndexOf('function Invoke-MaindEcmWindowPostSecure'))
Assert-True (-not$secure.Contains('--post-data')) 'secure ECM still uses unsupported wget POST'
Assert-True ($secure.IndexOf('Claim-MaindEcmWindowPost')-lt$secure.IndexOf('Invoke-MaindNativeHttpPostTransport')) 'claim does not precede native transport'
Assert-True (-not$secure.Contains('Invoke-MaindTelnetHttpPostTransport')) 'secure ECM still uses telnet transport'

Write-Output 'RAW_HTTP_POST_TRANSPORT_TESTS=PASS cases=20'
