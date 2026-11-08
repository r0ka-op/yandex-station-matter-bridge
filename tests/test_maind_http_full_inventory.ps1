[CmdletBinding()]param([string]$OutputDirectory)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if(-not$OutputDirectory){$OutputDirectory=Join-Path $root ('results\tests\full-inventory-offline-'+(Get-Date -Format yyyyMMdd-HHmmss))}
$null=& (Join-Path $PSScriptRoot 'test_maind_http_inventory_helpers.ps1') `
    -OutputPath (Join-Path $OutputDirectory 'inventory_helper_tests.json')
& python (Join-Path $PSScriptRoot 'test_matter_tlv_decoder.py') 2>&1 | Set-Content -Encoding UTF8 `
    (Join-Path $OutputDirectory 'tlv_decoder_tests.json')
if($LASTEXITCODE-ne0){throw 'Matter TLV decoder tests failed'}
& (Join-Path $PSScriptRoot 'run_full_matter_controller_audit.ps1') -OutputDirectory $OutputDirectory
$result=Get-Content -Raw (Join-Path $OutputDirectory 'offline_harness_results.json')|ConvertFrom-Json
$case=@($result.cases|Where-Object name -eq 'entry:full-inventory')
if(-not$result.all_pass-or$case.Count-ne1-or$case[0].status-ne'PASS'){throw 'Full inventory production entry did not pass the offline harness'}
"FULL_INVENTORY_OFFLINE=PASS`nRESULTS=$OutputDirectory"
