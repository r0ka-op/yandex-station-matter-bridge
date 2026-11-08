[CmdletBinding()]
param([string]$OutputDirectory)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $root 'scripts\maind_http_target_helpers.ps1')
Set-MaindHttpTarget -NodeId 4660 -EndpointId 1
. (Join-Path $root 'scripts\maind_http_light_control_helpers.ps1')
if(-not $OutputDirectory){
    $OutputDirectory=Join-Path $root ('results\tests\visual-brightness-timing-'+(Get-Date -Format yyyyMMdd-HHmmss))
}
New-Item -ItemType Directory -Force $OutputDirectory|Out-Null
$result=Invoke-MaindBrightnessHold -Seconds 3
$result|ConvertTo-Json|Set-Content -Encoding utf8 (Join-Path $OutputDirectory 'timing.json')
if($result.requested_seconds-ne3-or$result.elapsed_ms-lt2800-or$result.elapsed_ms-gt5000){
    throw "Three-second hold outside tolerance: $($result.elapsed_ms) ms"
}
'VISUAL_BRIGHTNESS_TIMING=PASS'
