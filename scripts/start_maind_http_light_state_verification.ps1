[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ConfirmToken,
    [Parameter(Mandatory=$true)][string]$SshAlias,
    [Parameter(Mandatory=$true)][string]$StationIPv4,
    [Parameter(Mandatory=$true)][string]$StationIPv6,
    [Parameter(Mandatory=$true)][UInt64]$MatterNodeId,
    [UInt16]$MatterEndpointId=1
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$required='I_APPROVE_READ_ONLY_LIGHT_STATE_VERIFICATION'
if($ConfirmToken -cne $required){
    throw 'Refusing read-only verification: exact confirmation token required.'
}
$controller=Join-Path $PSScriptRoot 'start_maind_http_runtime_test.ps1'
& $controller `
    -ConfirmToken I_APPROVE_MAIND_HTTP_RUNTIME_TEST `
    -SshAlias $SshAlias -StationIPv4 $StationIPv4 -StationIPv6 $StationIPv6 `
    -MatterNodeId $MatterNodeId -MatterEndpointId $MatterEndpointId `
    -ReadLightStateVerification -LightStateVerificationToken $ConfirmToken
