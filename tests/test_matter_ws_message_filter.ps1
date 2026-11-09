[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\maind_http_multi_admin_ecm_helpers.ps1')

function Assert-Equal($Actual,$Expected,[string]$Name){if($Actual-cne$Expected){throw "$Name expected=$Expected actual=$Actual"}}
$expected='nodes-regression-1'
$frames=@(
    '{"fabric_id":1,"schema_version":14}',
    '{"message_id":"nodes-regression-1","result":[]}',
    '{"message_id":"other-request","result":[1]}',
    '{not-json'
)
$kinds=[Collections.Generic.List[string]]::new()
foreach($frame in $frames){
    try{$obj=ConvertFrom-Json $frame -NoEnumerate -ErrorAction Stop}catch{$kinds.Add('invalid');continue}
    $kinds.Add((Get-MatterWsEnvelopeKind -Message $obj -ExpectedMessageId $expected))
}
Assert-Equal $kinds[0] 'unsolicited' 'server-info'
Assert-Equal $kinds[1] 'matched_response' 'expected response'
Assert-Equal $kinds[2] 'foreign_response' 'foreign response'
Assert-Equal $kinds[3] 'invalid' 'invalid message'

$timeoutFrames=@('{"fabric_id":1}','{"message_id":"other-request","result":[]}','{bad')
$matched=$false
foreach($frame in $timeoutFrames){
    try{$obj=ConvertFrom-Json $frame -NoEnumerate -ErrorAction Stop}catch{continue}
    if((Get-MatterWsEnvelopeKind $obj $expected)-ceq'matched_response'){$matched=$true;break}
}
Assert-Equal $matched $false 'timeout sequence must not invent a response'

$reasonCases=@(
    @{reason='not-discovered';stage='discovery';discovered='absent'},
    @{reason='passcode-mismatch';stage='pase';discovered='present'},
    @{reason='invalid-payload';stage='payload-validation';discovered='absent'},
    @{reason='attestation-rejected';stage='device-attestation';discovered='present'},
    @{reason='timeout';stage=$null;discovered='unknown'},
    @{reason='other';stage=$null;discovered='unknown'}
)
foreach($case in $reasonCases){
    $message=[pscustomobject]@{message_id='commission-1';error_code=1;reason=$case.reason}
    $diagnostic=New-MatterJsCommissionErrorDiagnostic -Message $message -ElapsedSeconds 12.3456
    Assert-Equal $diagnostic.error_code 1L "error code $($case.reason)"
    Assert-Equal $diagnostic.reason $case.reason "reason $($case.reason)"
    Assert-Equal $diagnostic.commissioning_stage $case.stage "stage $($case.reason)"
    Assert-Equal $diagnostic.discovered_device $case.discovered "discovery $($case.reason)"
    Assert-Equal $diagnostic.elapsed_seconds 12.346 "elapsed $($case.reason)"
}

$withoutReason=[pscustomobject]@{message_id='commission-2';error_code=1;status=2;cluster_status=3;details='must never persist'}
$withoutReasonDiagnostic=New-MatterJsCommissionErrorDiagnostic -Message $withoutReason -ElapsedSeconds 1
Assert-Equal $withoutReasonDiagnostic.reason $null 'missing reason'
Assert-Equal $withoutReasonDiagnostic.status 2L 'Matter status'
Assert-Equal $withoutReasonDiagnostic.cluster_status 3L 'cluster status'
Assert-Equal $withoutReasonDiagnostic.commissioning_stage 'matter-status' 'status-derived stage'
Assert-Equal $withoutReasonDiagnostic.discovered_device 'present' 'status-derived discovery'
$serialized=$withoutReasonDiagnostic|ConvertTo-Json -Compress
if($serialized-match'details|must never persist|manualCode|qrCode|setup_pin|verifier|salt'){throw 'Structured diagnostic leaked a forbidden field.'}

$unknownReason=New-MatterJsCommissionErrorDiagnostic -Message ([pscustomobject]@{error_code=1;reason='future-value'}) -ElapsedSeconds 2
Assert-Equal $unknownReason.reason $null 'unknown reason must not be invented'
Assert-Equal $unknownReason.discovered_device 'unknown' 'unknown reason discovery'

$noResponse=New-MatterJsCommissionErrorDiagnostic -Message $null -ElapsedSeconds 30
Assert-Equal $noResponse.error_code $null 'timeout without response error code'
Assert-Equal $noResponse.reason $null 'timeout without response reason'
Assert-Equal $noResponse.discovered_device 'unknown' 'timeout without response discovery'

$runtime=Get-Content -Raw (Join-Path $root 'scripts\start_maind_http_runtime_test.ps1')
$wsStart=$runtime.IndexOf('function Invoke-MatterServerCommissionWithCodeSecure')
$wsEnd=$runtime.IndexOf('function Invoke-CapabilityAttributeRead')
$handlers=$runtime.Substring($wsStart,$wsEnd-$wsStart)
if($handlers-match'\$obj\.(message_id|error_code|error|result)'){throw 'Unsafe direct WebSocket property access remains.'}
if(($handlers.Split('Get-MatterWsEnvelopeKind').Count-1)-lt2){throw 'Both WebSocket response handlers must classify envelopes.'}
foreach($call in @('ConnectAsync','SendAsync','CloseAsync')){
    $unsafe=[regex]::Matches($handlers,"(?m)^(?!.*\[void\]).*\.$call\(.*GetResult\(\)")
    if($unsafe.Count){throw "$call leaks VoidTaskResult into the PowerShell pipeline."}
}

Write-Output 'MATTER_WS_MESSAGE_FILTER_TESTS=PASS cases=14'
