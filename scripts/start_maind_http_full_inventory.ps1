[CmdletBinding()]
param(
    [ValidateSet('Offline','Runtime')][string]$Mode='Offline',
    [switch]$EnableRuntimeInventory,
    [string]$ConfirmToken,
    [UInt64]$TargetNodeId=0,
    [string]$SshAlias,
    [string]$StationIPv4,
    [string]$StationIPv6,
    [ValidateRange(1,5000)][int]$MaxRequests=1000,
    [ValidateRange(1024,4194304)][int]$MaxResponseBytes=1048576,
    [ValidateRange(1048576,268435456)][long]$MaxTotalBytes=67108864,
    [ValidateRange(0,5000)][int]$RequestDelayMs=150,
    [ValidateRange(60,1800)][int]$MaxSessionSeconds=600,
    [string]$OutputDirectory
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if($Mode-ceq'Offline'){
    if($EnableRuntimeInventory-or-not[string]::IsNullOrEmpty($ConfirmToken)){throw 'Runtime switches are forbidden in Offline mode'}
    & (Join-Path $root 'tests\test_maind_http_full_inventory.ps1') -OutputDirectory $OutputDirectory
    return
}
if(-not$EnableRuntimeInventory-or$ConfirmToken-cne'I_APPROVE_ONE_READ_ONLY_FULL_MATTER_INVENTORY'){
    throw 'Runtime inventory requires its explicit switch and exact unique confirmation token.'
}
if($TargetNodeId -lt 1 -or [string]::IsNullOrWhiteSpace($SshAlias) -or
   [string]::IsNullOrWhiteSpace($StationIPv4) -or [string]::IsNullOrWhiteSpace($StationIPv6)){
    throw 'Runtime inventory requires explicit target node, SSH alias, station IPv4 and station IPv6.'
}
& (Join-Path $PSScriptRoot 'start_maind_http_runtime_test.ps1') `
    -ConfirmToken I_APPROVE_MAIND_HTTP_RUNTIME_TEST `
    -MatterNodeId $TargetNodeId -MatterEndpointId 1 `
    -InternalFullInventory -InventoryTargetNodeId $TargetNodeId `
    -InventoryMaxRequests $MaxRequests -InventoryMaxResponseBytes $MaxResponseBytes `
    -InventoryMaxTotalBytes $MaxTotalBytes -InventoryRequestDelayMs $RequestDelayMs `
    -InventoryMaxSessionSeconds $MaxSessionSeconds `
    -SshAlias $SshAlias -StationIPv4 $StationIPv4 -StationIPv6 $StationIPv6
