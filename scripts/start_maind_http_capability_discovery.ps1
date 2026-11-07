[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfirmToken,
    [Parameter(Mandatory = $true)]
    [switch]$CapabilityDiscovery,
    [Parameter(Mandatory=$true)][string]$SshAlias,
    [Parameter(Mandatory=$true)][string]$StationIPv4,
    [Parameter(Mandatory=$true)][string]$StationIPv6,
    [Parameter(Mandatory=$true)][UInt64]$MatterNodeId,
    [UInt16]$MatterEndpointId=1
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($ConfirmToken -cne 'I_APPROVE_READ_ONLY_CAPABILITY_DISCOVERY') {
    throw 'Refusing to start: exact read-only capability confirmation token required.'
}
if (-not $CapabilityDiscovery.IsPresent) {
    throw 'Refusing to start without the explicit CapabilityDiscovery switch.'
}
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
& (Join-Path $root 'scripts\start_maind_http_runtime_test.ps1') `
    -ConfirmToken 'I_APPROVE_MAIND_HTTP_RUNTIME_TEST' `
    -SshAlias $SshAlias `
    -StationIPv4 $StationIPv4 `
    -StationIPv6 $StationIPv6 `
    -MatterNodeId $MatterNodeId `
    -MatterEndpointId $MatterEndpointId `
    -CapabilityDiscovery
