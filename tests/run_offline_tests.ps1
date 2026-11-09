[CmdletBinding()]
param([string]$OutputDirectory)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
if(-not $OutputDirectory){$OutputDirectory=Join-Path $root ('results\tests\offline-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))}
New-Item -ItemType Directory -Force -Path $OutputDirectory|Out-Null
$cases=[Collections.Generic.List[object]]::new()
function Invoke-Case([string]$Name,[scriptblock]$Action){
    $started=[DateTime]::UtcNow
    try{$output=& $Action 2>&1|Out-String;$cases.Add([pscustomobject][ordered]@{name=$Name;status='PASS';started_utc=$started.ToString('o');ended_utc=[DateTime]::UtcNow.ToString('o');message=$output.Trim()})}
    catch{$cases.Add([pscustomobject][ordered]@{name=$Name;status='FAIL';started_utc=$started.ToString('o');ended_utc=[DateTime]::UtcNow.ToString('o');message=$_.Exception.ToString()})}
}
Invoke-Case 'powershell_ast_all' {
    $bad=@()
    foreach($file in Get-ChildItem -LiteralPath $root -Recurse -Filter '*.ps1'){$tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors);if($errors.Count){$bad += "$($file.FullName): $($errors.Message -join '; ')"}}
    if($bad){throw ($bad -join [Environment]::NewLine)}
    'All PowerShell files parsed.'
}
Invoke-Case 'python_compile' {
    $py=(Get-Command python -ErrorAction Stop).Source
    $files=Get-ChildItem -LiteralPath $root -Recurse -Filter '*.py'|Where-Object {$_.FullName -notmatch '[\\/](bin|obj|__pycache__)[\\/]'}
    foreach($file in $files){& $py -m py_compile $file.FullName;if($LASTEXITCODE){throw "py_compile failed: $($file.FullName)"}}
    "Compiled $($files.Count) Python files."
}
Invoke-Case 'remote_shell_syntax' {
    $wsl=Get-Command wsl.exe -ErrorAction SilentlyContinue
    $bashCandidates=@((Get-Command bash -ErrorAction SilentlyContinue|Select-Object -ExpandProperty Source -First 1),'C:\Program Files\Git\bin\bash.exe')|Where-Object{$_ -and (Test-Path -LiteralPath $_)}|Select-Object -Unique
    if(-not $wsl -and -not $bashCandidates){throw 'WSL sh or Git Bash is required to run sh -n offline'}
    foreach($file in Get-ChildItem -LiteralPath $root -Recurse -Filter '*.sh'){
        $posix=$file.FullName.Replace('\','/')
        if($wsl){if($posix -match '^([A-Za-z]):/(.*)$'){$posix='/mnt/'+$Matches[1].ToLower()+'/'+$Matches[2]};& $wsl.Source sh -n $posix}
        else{$bash=$bashCandidates[0];& $bash -n $posix}
        if($LASTEXITCODE){throw "sh -n failed: $($file.FullName)"}
    }
    'All shell files passed sh -n.'
}
$python=(Get-Command python -ErrorAction Stop).Source
Invoke-Case 'matter_tlv_decoder' {& $python (Join-Path $PSScriptRoot 'test_matter_tlv_decoder.py');if($LASTEXITCODE){throw 'TLV tests failed'}}
Invoke-Case 'rollback_model' {& $python (Join-Path $PSScriptRoot 'test_maind_http_rollback.py');if($LASTEXITCODE){throw 'Rollback tests failed'}}
foreach($name in @('test_maind_http_controller.ps1','test_maind_http_raw_post_transport.ps1','test_matter_ws_message_filter.ps1','test_maind_http_onoff_control.ps1','test_maind_http_capability_discovery.ps1','test_maind_http_light_control.ps1','test_maind_http_light_state_verification.ps1','test_maind_http_strictmode.ps1','test_maind_http_visual_brightness_timing.ps1')){Invoke-Case $name {& (Join-Path $PSScriptRoot $name)}}
Invoke-Case 'production_end_to_end_and_fault_injection' {& (Join-Path $PSScriptRoot 'run_full_matter_controller_audit.ps1') -OutputDirectory (Join-Path $OutputDirectory 'full-audit')}
$summary=[pscustomobject][ordered]@{generated_utc=[DateTime]::UtcNow.ToString('o');runtime=$PSVersionTable.PSVersion.ToString();station_contacted=$false;cases=@($cases);passed=@($cases|Where-Object status -eq 'PASS').Count;failed=@($cases|Where-Object status -eq 'FAIL').Count}
$summary|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $OutputDirectory 'offline-tests.json') -Encoding utf8
$summary.cases|Format-Table name,status,message -AutoSize
if($summary.failed){throw "$($summary.failed) offline test group(s) failed; see $OutputDirectory"}
"OFFLINE_TESTS=PASS groups=$($summary.passed) results=$OutputDirectory"

