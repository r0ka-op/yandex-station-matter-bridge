[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][switch]$EnableBrightnessExperiment,
    [Parameter(Mandatory=$true)][string]$ConfirmToken,
    [switch]$AllowTemporaryOn,
    [string]$TemporaryOnConfirmToken,
    [Parameter(Mandatory=$true)][string]$SshAlias,
    [Parameter(Mandatory=$true)][string]$StationIPv4,
    [Parameter(Mandatory=$true)][string]$StationIPv6,
    [Parameter(Mandatory=$true)][UInt64]$MatterNodeId,
    [UInt16]$MatterEndpointId=1
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if (-not $EnableBrightnessExperiment -or $ConfirmToken -cne 'I_APPROVE_SMALL_BRIGHTNESS_CHANGE_AND_RESTORE') {
    throw 'Exact brightness switch and confirmation token required.'
}
if ($AllowTemporaryOn -and $TemporaryOnConfirmToken -cne 'I_APPROVE_TEMPORARY_ON_AND_RESTORE') {
    throw 'Temporary On requires its separate exact confirmation token.'
}
& (Join-Path $PSScriptRoot 'start_maind_http_runtime_test.ps1') `
    -ConfirmToken I_APPROVE_MAIND_HTTP_RUNTIME_TEST -SshAlias $SshAlias `
    -StationIPv4 $StationIPv4 -StationIPv6 $StationIPv6 `
    -MatterNodeId $MatterNodeId -MatterEndpointId $MatterEndpointId `
    -InternalBrightnessControl -LightControlConfirmToken $ConfirmToken `
    -AllowTemporaryOn:$AllowTemporaryOn -TemporaryOnConfirmToken $TemporaryOnConfirmToken
