[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][switch]$EnableSingleOnOffChange,
    [Parameter(Mandatory = $true)][string]$ConfirmToken,
    [Parameter(Mandatory=$true)][string]$SshAlias,
    [Parameter(Mandatory=$true)][string]$StationIPv4,
    [Parameter(Mandatory=$true)][string]$StationIPv6,
    [Parameter(Mandatory=$true)][UInt64]$MatterNodeId,
    [UInt16]$MatterEndpointId=1
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$required = 'I_APPROVE_SINGLE_ONOFF_CHANGE_AND_RESTORE'
if (-not $EnableSingleOnOffChange.IsPresent -or $ConfirmToken -cne $required) {
    throw 'Refusing control test: explicit switch and exact control confirmation token required.'
}

$engine = Join-Path $PSScriptRoot 'start_maind_http_runtime_test.ps1'
& $engine `
    -ConfirmToken I_APPROVE_MAIND_HTTP_RUNTIME_TEST `
    -SshAlias $SshAlias `
    -StationIPv4 $StationIPv4 `
    -StationIPv6 $StationIPv6 `
    -MatterNodeId $MatterNodeId `
    -MatterEndpointId $MatterEndpointId `
    -InternalOnOffControl `
    -ControlConfirmToken $ConfirmToken
