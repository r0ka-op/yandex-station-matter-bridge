[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\maind_http_target_helpers.ps1')
Set-MaindHttpTarget -NodeId 258 -EndpointId 1
. (Join-Path $root 'scripts\maind_http_light_state_verification_helpers.ps1')
. (Join-Path $root 'scripts\maind_http_response_helpers.ps1')
. (Join-Path $root 'scripts\maind_http_capability_helpers.ps1')
. (Join-Path $root 'scripts\maind_http_light_control_helpers.ps1')

function Assert-True([bool]$Value,[string]$Message){if(-not $Value){throw $Message}}
function Assert-False([bool]$Value,[string]$Message){if($Value){throw $Message}}

$devices=$null
Assert-True (Test-MaindLightStateVerificationRequestAllowed GET /devices $devices) 'GET /devices rejected'
$onJson=Get-MaindLightStateVerificationReadJson 6
$levelJson=Get-MaindLightStateVerificationReadJson 8
Assert-True (Test-MaindLightStateVerificationRequestAllowed POST /interaction/readAttribute $onJson) 'OnOff read rejected'
Assert-True (Test-MaindLightStateVerificationRequestAllowed POST /interaction/readAttribute $levelJson) 'level read rejected'
foreach($bad in @(
    @{m='POST';p='/interaction/invokeCommand';b='{"nodeId":258,"endpointId":1,"clusterId":6,"commandId":0,"fields":{}}'},
    @{m='POST';p='/interaction/writeAttribute';b='{}'},
    @{m='GET';p='/';b=$null},
    @{m='POST';p='/interaction/readAttribute';b='{"nodeId":258,"endpointId":1,"clusterId":768,"attributeId":0}'},
    @{m='POST';p='/interaction/readAttribute';b='{"nodeId":259,"endpointId":1,"clusterId":6,"attributeId":0}'},
    @{m='POST';p='/interaction/readAttribute';b='{"nodeId":258,"endpointId":2,"clusterId":6,"attributeId":0}'},
    @{m='POST';p='/interaction/readAttribute';b='not-json'}
)){
    Assert-False (Test-MaindLightStateVerificationRequestAllowed $bad.m $bad.p $bad.b) "unsafe request allowed: $($bad.m) $($bad.p)"
}

$onBody='{"errors":[],"values":[{"endpointId":1,"clusterId":6,"attributeId":0,"rawValue":"0x08"}]}'
$levelBody='{"errors":[],"values":[{"endpointId":1,"clusterId":8,"attributeId":0,"rawValue":"0x0404"}]}'
$on=Get-MaindBooleanAttributeState $onBody 6 0 $root
$level=Get-MaindUnsignedAttributeState $levelBody 8 0 $root
Assert-True (-not $on.value) 'Boolean false decoded incorrectly'
Assert-True ($level.value -eq 4) 'unsigned level decoded incorrectly'
$match=Compare-MaindLightStateWithExpected $on.value $level.value
Assert-True $match.light_state_verified 'expected state did not verify'
$mismatch=Compare-MaindLightStateWithExpected $true 5
Assert-False $mismatch.light_state_verified 'mismatched state incorrectly verified'

# Static production-path assertions ensure the tested allowlist is the one
# called by the runtime controller and that mutation routes are absent from it.
$controller=Get-Content -Raw (Join-Path $root 'scripts\start_maind_http_runtime_test.ps1')
Assert-True ($controller.Contains('Assert-MaindLightStateVerificationRequestAllowed')) 'runtime does not call strict verification allowlist'
Assert-True ($controller.Contains("-LightStateVerificationEnabled `$true")) 'verification reads do not select strict mode'
$helper=Get-Content -Raw (Join-Path $root 'scripts\maind_http_light_state_verification_helpers.ps1')
Assert-False ($helper.Contains("'/interaction/invokeCommand'")) 'verification helper contains invoke route'
Assert-False ($helper.Contains("'/interaction/writeAttribute'")) 'verification helper contains write route'

'LIGHT_STATE_VERIFICATION_MOCK=PASS'
