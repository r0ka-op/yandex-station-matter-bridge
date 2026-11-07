[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][switch]$EnableVendorReadOnlyDiscovery,
    [Parameter(Mandatory=$true)][string]$ConfirmToken,
    [Parameter(Mandatory=$true)][string]$SshAlias,
    [Parameter(Mandatory=$true)][string]$StationIPv4,
    [Parameter(Mandatory=$true)][string]$StationIPv6,
    [Parameter(Mandatory=$true)][UInt64]$MatterNodeId,
    [UInt16]$MatterEndpointId=1
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if (-not $EnableVendorReadOnlyDiscovery -or $ConfirmToken -cne 'I_APPROVE_READ_ONLY_YANDEX_COLOR_MUSIC_DISCOVERY') {
    throw 'Exact vendor read-only switch and confirmation token required.'
}
& (Join-Path $PSScriptRoot 'start_maind_http_runtime_test.ps1') `
    -ConfirmToken I_APPROVE_MAIND_HTTP_RUNTIME_TEST -SshAlias $SshAlias `
    -StationIPv4 $StationIPv4 -StationIPv6 $StationIPv6 `
    -MatterNodeId $MatterNodeId -MatterEndpointId $MatterEndpointId `
    -VendorColorMusicDiscovery
