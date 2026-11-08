[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $root 'scripts\maind_http_target_helpers.ps1')
Set-MaindHttpTarget -NodeId 4660 -EndpointId 1
. (Join-Path $root 'scripts\maind_http_response_helpers.ps1')
. (Join-Path $root 'scripts\maind_http_onoff_control_helpers.ps1')
. (Join-Path $root 'scripts\maind_http_capability_helpers.ps1')
. (Join-Path $root 'scripts\maind_http_light_control_helpers.ps1')
function Assert-Rejected([scriptblock]$Action,[string]$Name){$rejected=$false;try{&$Action}catch{$rejected=$true};if(-not$rejected){throw "$Name was accepted"}}
function Assert-True([bool]$Value,[string]$Name){if(-not$Value){throw $Name}}

foreach($body in @('', 'null','[]','{}','{"errors":null,"values":[]}','{"errors":[]}',
    '{"errors":[],"values":null}',
    '{"errors":[],"values":[{"endpointId":1,"clusterId":6,"attributeId":0}]}')){
    Assert-Rejected {Get-MaindAttributeResult $body 6 0} "malformed read envelope: $body"
    Assert-Rejected {Get-MaindOnOffStateFromReadResponse $body} "malformed OnOff envelope: $body"
}
Assert-Rejected {Assert-MaindInvokeSucceeded '{}'} 'invoke without responses'
Assert-Rejected {Assert-MaindInvokeSucceeded '{"responses":null}'} 'invoke null responses'
Assert-Rejected {Assert-MaindInvokeSucceeded '{"responses":[]}'} 'invoke empty responses'
Assert-Rejected {Assert-MaindInvokeSucceeded '{"responses":[{"endpointId":1,"clusterId":6,"commandId":1}]}' } 'invoke missing status'
Assert-Rejected {Assert-MaindInvokeSucceeded '{"errors":null,"responses":[]}' } 'invoke null errors'
$invoke=Assert-MaindInvokeSucceeded '{"responses":[{"endpointId":1,"clusterId":6,"commandId":1,"status":"x: Success"}]}' 1 6 1
Assert-True ($null -ne $invoke) 'valid invoke without errors rejected'

# AST semantic guard for the exact class of bug that parses as a command named
# "if" inside parentheses but fails at runtime.
foreach($file in Get-ChildItem (Join-Path $root 'scripts') -Filter *.ps1 -File){
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    $bad=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'if'},$true))
    if($bad.Count){throw "runtime-invalid parenthesized if command in $($file.Name)"}
}
'STRICTMODE_TESTS=PASS'
