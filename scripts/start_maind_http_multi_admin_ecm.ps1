[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ConfirmToken,
    [Parameter(Mandatory=$true)][string]$SshAlias,
    [Parameter(Mandatory=$true)][string]$StationIPv4,
    [Parameter(Mandatory=$true)][string]$StationIPv6,
    [Parameter(Mandatory=$true)][ValidateRange(1,[UInt64]::MaxValue)][UInt64]$ExpectedNodeId,
    [Parameter(Mandatory=$true)][Uri]$MatterServerWebSocketUri,
    [ValidateRange(180,900)][int]$CommissioningTimeoutSeconds=600,
    [ValidateRange(60,600)][int]$MatterJsDiscoveryTimeoutSeconds=300,
    [ValidateRange(1500,1800)][int]$WatchdogSeconds=1500,
    [ValidateRange(0,4095)][int]$Discriminator=0
)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if($ConfirmToken-cne'I_APPROVE_ONE_MULTI_ADMIN_ECM_SESSION'){
    throw 'Refusing to run: exact one-session MultiAdminECM token required.'
}
if($ExpectedNodeId-eq4660){throw 'Refusing demonstration Node ID 4660.'}
$runtime=Join-Path $PSScriptRoot 'start_maind_http_runtime_test.ps1'
& $runtime -ConfirmToken I_APPROVE_MAIND_HTTP_RUNTIME_TEST -SshAlias $SshAlias `
    -StationIPv4 $StationIPv4 -StationIPv6 $StationIPv6 -MatterNodeId $ExpectedNodeId `
    -MatterEndpointId 1 -InventoryTargetNodeId $ExpectedNodeId `
    -MultiAdminECM -MultiAdminECMConfirmToken $ConfirmToken `
    -EcmCommissioningTimeoutSeconds $CommissioningTimeoutSeconds `
    -MatterJsDiscoveryTimeoutSeconds $MatterJsDiscoveryTimeoutSeconds `
    -EcmWatchdogSeconds $WatchdogSeconds -EcmDiscriminator $Discriminator `
    -MatterServerWebSocketUri $MatterServerWebSocketUri
if(-not$?){throw 'MultiAdminECM lifecycle failed'}
