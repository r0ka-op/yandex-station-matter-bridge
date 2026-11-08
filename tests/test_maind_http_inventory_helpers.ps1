[CmdletBinding()]
param([string]$OutputPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $root 'scripts\maind_http_capability_helpers.ps1')
. (Join-Path $root 'scripts\maind_http_inventory_helpers.ps1')
$cases=[Collections.Generic.List[object]]::new()
function Test-Case([string]$Name,[scriptblock]$Action){
    try{&$Action;$cases.Add([pscustomobject]@{name=$Name;status='PASS';message='ok'})}
    catch{$cases.Add([pscustomobject]@{name=$Name;status='FAIL';message=$_.Exception.Message});throw}
}
function Assert-Inventory([bool]$Value,[string]$Message){if(-not$Value){throw $Message}}

$context=New-MaindInventoryContext -NodeId 4660
Add-MaindInventoryEndpoint $context 0
Test-Case 'allow:get-devices' {Assert-Inventory (Test-MaindInventoryRequestAllowed $context GET /devices '') 'GET /devices rejected'}
Test-Case 'deny:invoke-command' {Assert-Inventory (-not(Test-MaindInventoryRequestAllowed $context POST /interaction/invokeCommand '{}')) 'invokeCommand admitted'}
Test-Case 'deny:write-attribute' {Assert-Inventory (-not(Test-MaindInventoryRequestAllowed $context POST /interaction/writeAttribute '{}')) 'writeAttribute admitted'}
Test-Case 'allow:descriptor-bootstrap' {$body=Get-MaindInventoryReadJson 4660 0 29 1;Assert-Inventory (Test-MaindInventoryRequestAllowed $context POST /interaction/readAttribute $body) 'Descriptor bootstrap rejected'}
Test-Case 'deny:unproven-endpoint' {$body=Get-MaindInventoryReadJson 4660 9 29 1;Assert-Inventory (-not(Test-MaindInventoryRequestAllowed $context POST /interaction/readAttribute $body)) 'unproven endpoint admitted'}
Test-Case 'deny:unproven-cluster' {$body=Get-MaindInventoryReadJson 4660 0 6 65531;Assert-Inventory (-not(Test-MaindInventoryRequestAllowed $context POST /interaction/readAttribute $body)) 'unproven cluster admitted'}
Add-MaindInventoryServerCluster $context 0 6
Test-Case 'allow:global-after-server-list' {$body=Get-MaindInventoryReadJson 4660 0 6 65531;Assert-Inventory (Test-MaindInventoryRequestAllowed $context POST /interaction/readAttribute $body) 'global rejected'}
Test-Case 'deny:unproven-ordinary-attribute' {$body=Get-MaindInventoryReadJson 4660 0 6 0;Assert-Inventory (-not(Test-MaindInventoryRequestAllowed $context POST /interaction/readAttribute $body)) 'ordinary attribute admitted without AttributeList evidence'}
Add-MaindInventoryAttribute $context 0 6 0
Test-Case 'allow:attribute-list-member' {$body=Get-MaindInventoryReadJson 4660 0 6 0;Assert-Inventory (Test-MaindInventoryRequestAllowed $context POST /interaction/readAttribute $body) 'AttributeList member rejected'}

Test-Case 'parse:success-null' {
    $body='{"errors":[],"values":[{"endpointId":0,"clusterId":6,"attributeId":0,"rawValue":"0x14","dataVersion":9}]}'
    $read=Get-MaindInventoryAttributeResult $body 0 6 0
    $decoded=ConvertFrom-MaindMatterTlv $read.value.rawValue $root
    Assert-Inventory ($read.supported-and$read.data_version-eq9-and$decoded.elements[0].type-eq'null') 'nullable TLV was not retained'
}
Test-Case 'parse:access-denied' {
    $read=Get-MaindInventoryAttributeResult '{"errors":[{"status":"ACCESS_DENIED"}],"values":[]}' 0 62 0
    Assert-Inventory (-not$read.supported-and$read.error_class-eq'ACCESS_DENIED') 'access error misclassified'
}
Test-Case 'parse:missing-values-rejected' {
    $thrown=$false;try{[void](Get-MaindInventoryAttributeResult '{"errors":[]}' 0 6 0)}catch{$thrown=$true}
    Assert-Inventory $thrown 'incomplete response accepted'
}
Test-Case 'decode:nested-containers' {
    $decoded=ConvertFrom-MaindMatterTlv '0x161510030102031818' $root
    $plain=@(ConvertFrom-MaindInventoryTlvDocument $decoded)
    Assert-Inventory ($plain[0].type-eq'array'-and$plain[0].children[0].type-eq'structure'-and$plain[0].children[0].children[0].value_hex-eq'010203') 'nested bytes were not preserved'
}

$failed=@($cases|Where-Object status -eq 'FAIL')
$result=[ordered]@{generated_utc=[DateTime]::UtcNow.ToString('o');all_pass=($failed.Count-eq0);case_count=$cases.Count;failed_count=$failed.Count;cases=@($cases)}
$resultObject=[pscustomobject]$result
if($OutputPath){$parent=Split-Path -Parent $OutputPath;if($parent){New-Item -ItemType Directory -Force $parent|Out-Null};$resultObject|ConvertTo-Json -Depth 8|Set-Content -Encoding UTF8 $OutputPath}
$resultObject
