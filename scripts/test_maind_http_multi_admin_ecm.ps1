$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'maind_http_multi_admin_ecm_helpers.ps1')
. (Join-Path $PSScriptRoot 'maind_http_capability_helpers.ps1')
function Assert-True([bool]$Value,[string]$Message){if(-not$Value){throw $Message}}
function Assert-False([bool]$Value,[string]$Message){if($Value){throw $Message}}

$context=New-MaindEcmContext -ExpectedNodeId 42 -CommissioningTimeoutSeconds 300 -Discriminator 1234
$devices='[{"nodeId":42,"endpoints":[0,1]}]'
Assert-True ((Resolve-MaindEcmTargetFromDevices $context $devices)-eq42) 'Node resolution failed'
Assert-True (Test-MaindEcmRequestAllowed $context GET /devices $null) 'GET /devices rejected'
$plan=@(Get-MaindEcmBaselineReadPlan 258)
Assert-True ($plan.Count-eq5) 'baseline must contain exactly five unique reads'
Assert-True (@($plan|ForEach-Object{"$($_.clusterId)/$($_.attributeId)"}|Select-Object -Unique).Count-eq5) 'duplicate baseline reads'
foreach($item in $plan){
    $json=Get-MaindEcmReadRequestJson 42 $item.clusterId $item.attributeId
    Assert-True (Test-MaindEcmRequestAllowed $context POST /interaction/readAttribute $json) "read rejected: $($item.name)"
}
$window=Get-MaindEcmWindowRequestJson $context
Assert-True (Test-MaindEcmRequestAllowed $context POST /commissioning/window $window) 'window POST rejected before claim'

foreach($case in @(
    @{m='POST';p='/interaction/invokeCommand';b='{}'},
    @{m='POST';p='/interaction/writeAttribute';b='{}'},
    @{m='DELETE';p='/devices/258';b=$null},
    @{m='POST';p='/commissioning/window';b='{"nodeId":259,"discriminator":1234,"timeout":300}'},
    @{m='POST';p='/commissioning/window';b='{"nodeId":42,"discriminator":1234,"timeout":300,"extra":1}'},
    @{m='POST';p='/interaction/readAttribute';b='{"nodeId":42,"endpointId":0,"clusterId":31,"attributeId":0}'}
)) { Assert-False (Test-MaindEcmRequestAllowed $context $case.m $case.p $case.b) "forbidden route accepted: $($case.m) $($case.p)" }

$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ("multi-admin-ecm-test-"+[Guid]::NewGuid().ToString('N'))
$claim=Join-Path $tempRoot 'window-post.claimed.json'
Claim-MaindEcmWindowPost $context $claim
Assert-False (Test-MaindEcmRequestAllowed $context POST /commissioning/window $window) 'repeat POST remained allowlisted'
$repeatBlocked=$false
try{Claim-MaindEcmWindowPost $context $claim}catch{$repeatBlocked=$true}
Assert-True $repeatBlocked 'repeat claim was not blocked'
$commissionClaim=Join-Path $tempRoot 'matterjs-commission.claimed.json'
Claim-MaindEcmMatterCommission $context $commissionClaim
$commissionRepeatBlocked=$false
try{Claim-MaindEcmMatterCommission $context $commissionClaim}catch{$commissionRepeatBlocked=$true}
Assert-True $commissionRepeatBlocked 'repeat Matter.js commissioning claim was not blocked'

$timing=New-MaindEcmTimingContext -WatchdogSeconds 1500
$timingSummary=Get-MaindEcmTimingSummary $timing
Assert-True ($timingSummary.main_deadline_seconds-eq1140) 'main deadline must be 1140 seconds'
Assert-True ($timingSummary.rollback_deadline_seconds-eq1380) 'rollback deadline must be 1380 seconds'
Assert-True ($timingSummary.rollback_budget_seconds-eq240) 'rollback budget must be 240 seconds'
Assert-True ($timingSummary.watchdog_safety_seconds-eq120) 'watchdog safety reserve must be 120 seconds'
$bounded=Get-MaindEcmBoundedTimeoutMilliseconds $timing 10 Preparation
Assert-True ($bounded-gt0-and$bounded-le10000) 'bounded timeout did not honor local limit'

$syntheticManual=('1'*11);$syntheticQr='MT:SYNTHETIC-OFFLINE-ONLY'
$response=ConvertFrom-MaindEcmWindowResponse (ConvertTo-Json -Compress @{manualCode=$syntheticManual;qrCode=$syntheticQr})
$summary=Get-MaindEcmRedactedSummary $response|ConvertTo-Json -Compress
Assert-False ($summary.Contains($syntheticManual)) 'manualCode leaked into summary'
Assert-False ($summary.Contains($syntheticQr)) 'qrCode leaked into summary'
$redacted=Protect-MaindEcmDiagnosticText "manualCode=$syntheticManual qrCode=$syntheticQr salt=abcd verifier=efgh"
Assert-False ($redacted.Contains($syntheticManual)-or$redacted.Contains($syntheticQr)-or$redacted.Contains('abcd')-or$redacted.Contains('efgh')) 'diagnostic redaction failed'

$demoRejected=$false
try{New-MaindEcmContext -ExpectedNodeId 4660 -CommissioningTimeoutSeconds 300 -Discriminator 1}catch{$demoRejected=$true}
Assert-True $demoRejected 'demonstration Node ID accepted'
$mismatchRejected=$false
try{Resolve-MaindEcmTargetFromDevices (New-MaindEcmContext 42 300 1) '[{"nodeId":43,"endpoints":[0,1]}]'}catch{$mismatchRejected=$true}
Assert-True $mismatchRejected 'Node ID mismatch accepted'
$endpointZero=Get-MaindAttributeResult -JsonText '{"errors":[],"values":[{"endpointId":0,"clusterId":60,"attributeId":0,"rawValue":"0x04"}]}' `
    -ClusterId 60 -AttributeId 0 -EndpointId 0
Assert-True ($endpointZero.supported-and$endpointZero.value.endpointId-eq0) 'endpoint 0 decoder contract failed'
Remove-Item -LiteralPath $tempRoot -Recurse -Force
Write-Output 'MULTI_ADMIN_ECM_HELPERS_TEST=PASS'
