[CmdletBinding()]
param(
    [string]$OutputDirectory
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
if(-not $OutputDirectory){$OutputDirectory=Join-Path $root ('results\tests\full-matter-controller-audit-'+(Get-Date -Format yyyyMMdd-HHmmss))}
New-Item -ItemType Directory -Force $OutputDirectory|Out-Null
$cases=[Collections.Generic.List[object]]::new()
function Add-Case($Name,$Status,$Message,$Artifacts=@()){$cases.Add([pscustomobject][ordered]@{name=$Name;status=$Status;message=$Message;artifacts=@($Artifacts)})}
function Assert-True([bool]$Value,[string]$Message){if(-not $Value){throw $Message}}
# Time is an external dependency in this harness. State transitions are
# synchronous in the mock transport, so production stabilization delays can be
# suppressed without replacing controller logic.
function Start-Sleep { param([int]$Seconds,[int]$Milliseconds) }
function Assert-EntryRejected([string]$Name,[scriptblock]$Action){
    $rejected=$false;$message=''
    try{&$Action}catch{$rejected=$true;$message=$_.Exception.Message}
    if($rejected){Add-Case "parameters:$Name" PASS $message}else{Add-Case "parameters:$Name" FAIL 'unsafe arguments accepted';throw "unsafe arguments accepted: $Name"}
}

# AST parse every PowerShell file.
foreach($file in Get-ChildItem (Join-Path $root 'scripts') -Filter *.ps1 -File){
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if($errors.Count){Add-Case "ast:$($file.Name)" FAIL (($errors.Message)-join '; ')}else{Add-Case "ast:$($file.Name)" PASS 'parsed'}
}

# Compile a binary ssh.exe shim. The production controller is executed without
# a test-only branch; only its external ssh process is replaced.
$shimRoot=Join-Path $OutputDirectory 'mock-windir'
$shimDir=Join-Path $shimRoot 'System32\OpenSSH';New-Item -ItemType Directory -Force $shimDir|Out-Null
$shim=Join-Path $shimDir 'ssh.exe'
if(Test-Path -LiteralPath $shim){Remove-Item -LiteralPath $shim -Force}
$launcherProject=Join-Path $root 'scripts\mock_ssh_launcher\MockSshLauncher.csproj'
& dotnet build $launcherProject -nologo -v:q -o $shimDir
if($LASTEXITCODE -ne 0 -or -not(Test-Path -LiteralPath $shim)){throw 'Could not build mock ssh launcher'}
$python=(Get-Command python -ErrorAction Stop).Source
$oldWindir=$env:WINDIR;$oldRoot=$env:MAIND_MOCK_ROOT;$oldPython=$env:MAIND_MOCK_PYTHON;$oldScript=$env:MAIND_MOCK_SSH_SCRIPT;$oldFault=$env:MAIND_MOCK_FAULT;$oldInitialOn=$env:MAIND_MOCK_INITIAL_ON
$env:WINDIR=$shimRoot;$env:MAIND_MOCK_PYTHON=$python;$env:MAIND_MOCK_SSH_SCRIPT=Join-Path $root 'tests\mock_maind_ssh_transport.py'

function Initialize-Mock([string]$Name,[string]$Fault='none',[bool]$InitialOn=$false){
    $caseRoot=Join-Path $OutputDirectory ('mock-'+$Name)
    if(Test-Path $caseRoot){Remove-Item -Recurse -Force $caseRoot}
    New-Item -ItemType Directory -Force (Join-Path $caseRoot 'remote\tmp')|Out-Null
    if($Name -eq 'light-verification'){
        New-Item -ItemType Directory -Force (Join-Path $caseRoot 'remote\tmp\maind-http-test')|Out-Null
        Set-Content -NoNewline -Encoding ascii (Join-Path $caseRoot 'remote\tmp\maind-http-test\LIGHT_STATE_MAY_BE_CHANGED') ''
        Set-Content -NoNewline -Encoding ascii (Join-Path $caseRoot 'remote\tmp\maind-http-test\light.restore.armed') ''
        Set-Content -Encoding ascii (Join-Path $caseRoot 'remote\tmp\maind-http-test\light.restore.state') "mode=brightness`nonoff=0`nonoff_raw=0x08`nlevel=4`nlevel_raw=0x0404"
    }
    $env:MAIND_MOCK_ROOT=$caseRoot;$env:MAIND_MOCK_FAULT=$Fault
    $env:MAIND_MOCK_INITIAL_ON=if($InitialOn){'1'}else{'0'}
    return $caseRoot
}
function Invoke-EntryCase([string]$Name,[scriptblock]$Action,[string[]]$ExpectedFiles,[bool]$ExpectFailure=$false,[string]$Fault='none',[bool]$InitialOn=$false,[bool]$RequireRollback=$true){
    $caseRoot=Initialize-Mock $Name $Fault $InitialOn
    $before=@(Get-ChildItem (Join-Path $root 'results\runtime') -Directory -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty FullName)
    $failed=$false;$message=''
    try{& $Action}catch{$failed=$true;$message=$_.Exception.Message}
    $after=@(Get-ChildItem (Join-Path $root 'results\runtime') -Directory -ErrorAction SilentlyContinue|Where-Object FullName -notin $before|Sort-Object LastWriteTime)
    $run=$after|Select-Object -Last 1
    try{
        if($ExpectFailure -ne $failed){throw "failure expectation mismatch expected=$ExpectFailure actual=$failed message=$message"}
        if($null -eq $run){throw 'production entry point created no result directory'}
        foreach($file in $ExpectedFiles){if(-not(Test-Path (Join-Path $run.FullName $file))){throw "missing result file $file"}}
        if(-not $ExpectFailure){
            $finalStatus=Join-Path $run.FullName 'final_status.txt'
            if(Test-Path $finalStatus){Assert-True ((Get-Content -Raw $finalStatus)-match 'completed=yes') 'final status is not clean/completed'}
            switch -Wildcard ($Name){
                'devices-only' { $data=Get-Content -Raw (Join-Path $run.FullName 'devices_structure.json')|ConvertFrom-Json;Assert-True ($data.target_found -and $data.target_endpoint_found) 'devices result lacks target endpoint' }
                'onoff-read' { $data=Get-Content -Raw (Join-Path $run.FullName 'read_onoff.parsed.json')|ConvertFrom-Json;Assert-True ($data.errors.Count-eq0) 'OnOff read contains errors' }
                'capability' { $data=Get-Content -Raw (Join-Path $run.FullName 'capability_discovery.json')|ConvertFrom-Json;Assert-True ($data.level_control.present-and$data.color_control.present) 'capability result incomplete' }
                'vendor' { $data=Get-Content -Raw (Join-Path $run.FullName 'yandex_color_music_discovery.json')|ConvertFrom-Json;Assert-True ($data.cluster_id-eq321911814) 'vendor cluster mismatch' }
                'light-verification' { $data=Get-Content -Raw (Join-Path $run.FullName 'light_state_verification.json')|ConvertFrom-Json;Assert-True ($data.light_state_verified-and-not$data.actual.onOff-and$data.actual.currentLevel-eq4) 'verification result content mismatch' }
                'onoff-control' { $data=Get-Content -Raw (Join-Path $run.FullName 'control_state_transition.json')|ConvertFrom-Json;Assert-True $data.restoration_verified 'OnOff restoration result false' }
                'brightness*' { $data=Get-Content -Raw (Join-Path $run.FullName 'light_control_result.json')|ConvertFrom-Json;Assert-True ($data.mode-eq'brightness'-and$data.restoration_verified) 'brightness result content mismatch' }
                'visual-brightness' { $data=Get-Content -Raw (Join-Path $run.FullName 'light_control_result.json')|ConvertFrom-Json;Assert-True ($data.mode-eq'brightness'-and$data.visual_brightness_test-and$data.test_level-eq64-and$data.restoration_verified) 'visual brightness result content mismatch';$timing=Get-Content -Raw (Join-Path $run.FullName 'brightness_timing.json')|ConvertFrom-Json;Assert-True ($timing.target_level-eq64-and$timing.requested_hold_seconds-eq3) 'visual brightness timing mismatch' }
                'visual-color*' { $data=Get-Content -Raw (Join-Path $run.FullName 'light_control_result.json')|ConvertFrom-Json;Assert-True ($data.mode-eq'color'-and$data.visual_color_test-and$data.test_level-eq64-and$data.restoration_verified) 'visual color result content mismatch';$timing=Get-Content -Raw (Join-Path $run.FullName 'color_visual_timing.json')|ConvertFrom-Json;Assert-True ($timing.target_level-eq64-and$timing.requested_hold_seconds-eq3-and$timing.target_hue-eq(($timing.baseline_hue+85)%255)) 'visual color timing mismatch' }
                'color*' { $data=Get-Content -Raw (Join-Path $run.FullName 'light_control_result.json')|ConvertFrom-Json;Assert-True ($data.mode-eq'color'-and$data.restoration_verified) 'color result content mismatch' }
            }
        }else{
            Assert-True ((Get-Item (Join-Path $run.FullName 'controller_error.txt')).Length-gt0) 'expected failure has empty controller_error.txt'
        }
        $log=Get-Content -Raw (Join-Path $caseRoot 'remote\tmp\maind-http-test\experiment.log') -ErrorAction SilentlyContinue
        if($RequireRollback -and $Name -ne 'light-verification' -and $log -notmatch 'rollback complete'){throw 'rollback was not recorded'}
        $caseMessage=if($failed){"expected failure: $message"}else{'completed'}
        Add-Case "entry:$Name" PASS $caseMessage $run.FullName
    }catch{
        $runArtifacts=if($null -ne $run){@($run.FullName)}else{@()}
        Add-Case "entry:$Name" FAIL $_.Exception.Message $runArtifacts
        throw
    }
}

try{
    $runtime=Join-Path $root 'scripts\start_maind_http_runtime_test.ps1'
    Assert-EntryRejected runtime-wrong-token {& $runtime -ConfirmToken WRONG}
    Assert-EntryRejected mutually-exclusive-modes {& $runtime -ConfirmToken I_APPROVE_MAIND_HTTP_RUNTIME_TEST -ReadOnOffAttribute -CapabilityDiscovery}
    Assert-EntryRejected temporary-on-without-light-mode {& $runtime -ConfirmToken I_APPROVE_MAIND_HTTP_RUNTIME_TEST -AllowTemporaryOn -TemporaryOnConfirmToken I_APPROVE_TEMPORARY_ON_AND_RESTORE}
    Assert-EntryRejected brightness-wrong-token {& (Join-Path $root 'scripts\start_maind_http_brightness_control_test.ps1') -EnableBrightnessExperiment -ConfirmToken WRONG}
    Assert-EntryRejected visual-brightness-wrong-token {& (Join-Path $root 'scripts\start_maind_http_brightness_visual_test.ps1') -EnableVisualBrightnessExperiment -ConfirmToken WRONG}
    Assert-EntryRejected color-wrong-token {& (Join-Path $root 'scripts\start_maind_http_color_control_test.ps1') -EnableColorExperiment -ConfirmToken WRONG}
    Assert-EntryRejected visual-color-wrong-token {& (Join-Path $root 'scripts\start_maind_http_color_visual_test.ps1') -EnableVisualColorExperiment -ConfirmToken WRONG}
    Assert-EntryRejected onoff-wrong-token {& (Join-Path $root 'scripts\start_maind_http_onoff_control_test.ps1') -EnableSingleOnOffChange -ConfirmToken WRONG}
    Assert-EntryRejected capability-missing-switch {& (Join-Path $root 'scripts\start_maind_http_capability_discovery.ps1') -CapabilityDiscovery:$false -ConfirmToken I_APPROVE_READ_ONLY_CAPABILITY_DISCOVERY}
    Assert-EntryRejected verification-wrong-token {& (Join-Path $root 'scripts\start_maind_http_light_state_verification.ps1') -ConfirmToken WRONG}
    Invoke-EntryCase staging-only {& $runtime -ConfirmToken I_APPROVE_MAIND_HTTP_RUNTIME_TEST -SshAlias mock -StationIPv4 127.0.0.1 -StationIPv6 ::1 -MatterNodeId 258 -MatterEndpointId 1 -StagingOnly} @() $false 'none' $false $false
    Invoke-EntryCase devices-only {& $runtime -ConfirmToken I_APPROVE_MAIND_HTTP_RUNTIME_TEST -SshAlias mock -StationIPv4 127.0.0.1 -StationIPv6 ::1 -MatterNodeId 258 -MatterEndpointId 1} @('devices.json','final_status.txt')
    Invoke-EntryCase onoff-read {& $runtime -ConfirmToken I_APPROVE_MAIND_HTTP_RUNTIME_TEST -SshAlias mock -StationIPv4 127.0.0.1 -StationIPv6 ::1 -MatterNodeId 258 -MatterEndpointId 1 -ReadOnOffAttribute} @('read_onoff.parsed.json','final_status.txt')
    Invoke-EntryCase capability {& (Join-Path $root 'scripts\start_maind_http_capability_discovery.ps1') -CapabilityDiscovery -ConfirmToken I_APPROVE_READ_ONLY_CAPABILITY_DISCOVERY -SshAlias mock -StationIPv4 127.0.0.1 -StationIPv6 ::1 -MatterNodeId 258 -MatterEndpointId 1} @('capability_discovery.json','final_status.txt')
    Invoke-EntryCase vendor {& (Join-Path $root 'scripts\start_maind_http_yandex_color_music_discovery.ps1') -EnableVendorReadOnlyDiscovery -ConfirmToken I_APPROVE_READ_ONLY_YANDEX_COLOR_MUSIC_DISCOVERY -SshAlias mock -StationIPv4 127.0.0.1 -StationIPv6 ::1 -MatterNodeId 258 -MatterEndpointId 1} @('yandex_color_music_discovery.json','final_status.txt')
    Invoke-EntryCase light-verification {& (Join-Path $root 'scripts\start_maind_http_light_state_verification.ps1') -ConfirmToken I_APPROVE_READ_ONLY_LIGHT_STATE_VERIFICATION -SshAlias mock -StationIPv4 127.0.0.1 -StationIPv6 ::1 -MatterNodeId 258 -MatterEndpointId 1} @('light_state_verification.json','LIGHT_STATE_VERIFIED.txt','final_status.txt')
    Invoke-EntryCase onoff-control {& (Join-Path $root 'scripts\start_maind_http_onoff_control_test.ps1') -EnableSingleOnOffChange -ConfirmToken I_APPROVE_SINGLE_ONOFF_CHANGE_AND_RESTORE -SshAlias mock -StationIPv4 127.0.0.1 -StationIPv6 ::1 -MatterNodeId 258 -MatterEndpointId 1} @('control_state_transition.json','final_status.txt')
    Invoke-EntryCase brightness {& (Join-Path $root 'scripts\start_maind_http_brightness_control_test.ps1') -EnableBrightnessExperiment -ConfirmToken I_APPROVE_SMALL_BRIGHTNESS_CHANGE_AND_RESTORE -AllowTemporaryOn -TemporaryOnConfirmToken I_APPROVE_TEMPORARY_ON_AND_RESTORE -SshAlias mock -StationIPv4 127.0.0.1 -StationIPv6 ::1 -MatterNodeId 258 -MatterEndpointId 1} @('light_control_result.json','final_status.txt')
    Invoke-EntryCase visual-brightness {& (Join-Path $root 'scripts\start_maind_http_brightness_visual_test.ps1') -EnableVisualBrightnessExperiment -ConfirmToken I_APPROVE_VISUAL_BRIGHTNESS_64_AND_RESTORE -AllowTemporaryOn -TemporaryOnConfirmToken I_APPROVE_TEMPORARY_ON_AND_RESTORE -SshAlias mock -StationIPv4 127.0.0.1 -StationIPv6 ::1 -MatterNodeId 258 -MatterEndpointId 1} @('light_control_result.json','brightness_timing.json','final_status.txt')
    Invoke-EntryCase color {& (Join-Path $root 'scripts\start_maind_http_color_control_test.ps1') -EnableColorExperiment -ConfirmToken I_APPROVE_SMALL_COLOR_CHANGE_AND_RESTORE -AllowTemporaryOn -TemporaryOnConfirmToken I_APPROVE_TEMPORARY_ON_AND_RESTORE -SshAlias mock -StationIPv4 127.0.0.1 -StationIPv6 ::1 -MatterNodeId 258 -MatterEndpointId 1} @('light_control_result.json','final_status.txt')
    Invoke-EntryCase visual-color {& (Join-Path $root 'scripts\start_maind_http_color_visual_test.ps1') -EnableVisualColorExperiment -ConfirmToken I_APPROVE_VISUAL_COLOR_85_LEVEL_64_AND_RESTORE -AllowTemporaryOn -TemporaryOnConfirmToken I_APPROVE_TEMPORARY_ON_AND_RESTORE -SshAlias mock -StationIPv4 127.0.0.1 -StationIPv6 ::1 -MatterNodeId 258 -MatterEndpointId 1} @('light_control_result.json','color_visual_timing.json','final_status.txt')
    Invoke-EntryCase brightness-initially-on {& (Join-Path $root 'scripts\start_maind_http_brightness_control_test.ps1') -EnableBrightnessExperiment -ConfirmToken I_APPROVE_SMALL_BRIGHTNESS_CHANGE_AND_RESTORE -SshAlias mock -StationIPv4 127.0.0.1 -StationIPv6 ::1 -MatterNodeId 258 -MatterEndpointId 1} @('light_control_result.json','final_status.txt') $false 'none' $true
    Invoke-EntryCase color-initially-on {& (Join-Path $root 'scripts\start_maind_http_color_control_test.ps1') -EnableColorExperiment -ConfirmToken I_APPROVE_SMALL_COLOR_CHANGE_AND_RESTORE -SshAlias mock -StationIPv4 127.0.0.1 -StationIPv6 ::1 -MatterNodeId 258 -MatterEndpointId 1} @('light_control_result.json','final_status.txt') $false 'none' $true
    Invoke-EntryCase visual-color-initially-on {& (Join-Path $root 'scripts\start_maind_http_color_visual_test.ps1') -EnableVisualColorExperiment -ConfirmToken I_APPROVE_VISUAL_COLOR_85_LEVEL_64_AND_RESTORE -SshAlias mock -StationIPv4 127.0.0.1 -StationIPv6 ::1 -MatterNodeId 258 -MatterEndpointId 1} @('light_control_result.json','color_visual_timing.json','final_status.txt') $false 'none' $true
    Invoke-EntryCase brightness-off-without-consent {& (Join-Path $root 'scripts\start_maind_http_brightness_control_test.ps1') -EnableBrightnessExperiment -ConfirmToken I_APPROVE_SMALL_BRIGHTNESS_CHANGE_AND_RESTORE -SshAlias mock -StationIPv4 127.0.0.1 -StationIPv6 ::1 -MatterNodeId 258 -MatterEndpointId 1} @('controller_error.txt') $true
    Invoke-EntryCase color-off-without-consent {& (Join-Path $root 'scripts\start_maind_http_color_control_test.ps1') -EnableColorExperiment -ConfirmToken I_APPROVE_SMALL_COLOR_CHANGE_AND_RESTORE -SshAlias mock -StationIPv4 127.0.0.1 -StationIPv6 ::1 -MatterNodeId 258 -MatterEndpointId 1} @('controller_error.txt') $true
    $transportFaults=[ordered]@{
        http404='HTTP route/handler error'
        http500='HTTP route/handler error'
        http503='HTTP route/handler error'
        empty='HTTP body error'
        invalid_json='invalid JSON'
        missing_properties='Node ID 258 was not found'
        ssh_loss='SSH transport exited with code 255'
        matter_timeout='HTTP protocol error'
    }
    foreach($fault in $transportFaults.Keys){
        Invoke-EntryCase "fault-$fault" {& $runtime -ConfirmToken I_APPROVE_MAIND_HTTP_RUNTIME_TEST -SshAlias mock -StationIPv4 127.0.0.1 -StationIPv6 ::1 -MatterNodeId 258 -MatterEndpointId 1 -ReadOnOffAttribute} @('controller_error.txt') $true $fault
        $lastCase=$cases[$cases.Count-1]
        if($lastCase.message -notlike "*$($transportFaults[$fault])*"){
            $lastCase.status='FAIL'
            $lastCase.message="wrong failure classification: $($lastCase.message)"
            throw "Fault $fault did not produce its expected diagnostic class"
        }
    }
    foreach($fault in @('read_missing_properties','read_invalid_json','read_empty','read_matter_error')){
        Invoke-EntryCase "fault-$fault" {& $runtime -ConfirmToken I_APPROVE_MAIND_HTTP_RUNTIME_TEST -SshAlias mock -StationIPv4 127.0.0.1 -StationIPv6 ::1 -MatterNodeId 258 -MatterEndpointId 1 -ReadOnOffAttribute} @('controller_error.txt') $true $fault
    }
    foreach($fault in @('invoke_unconfirmed','invoke_matter_error')){
        Invoke-EntryCase "fault-$fault" {& (Join-Path $root 'scripts\start_maind_http_onoff_control_test.ps1') -EnableSingleOnOffChange -ConfirmToken I_APPROVE_SINGLE_ONOFF_CHANGE_AND_RESTORE -SshAlias mock -StationIPv4 127.0.0.1 -StationIPv6 ::1 -MatterNodeId 258 -MatterEndpointId 1} @('controller_error.txt') $true $fault
    }
    Invoke-EntryCase 'fault-onoff-restore' {& (Join-Path $root 'scripts\start_maind_http_onoff_control_test.ps1') -EnableSingleOnOffChange -ConfirmToken I_APPROVE_SINGLE_ONOFF_CHANGE_AND_RESTORE -SshAlias mock -StationIPv4 127.0.0.1 -StationIPv6 ::1 -MatterNodeId 258 -MatterEndpointId 1} @('controller_error.txt','CONTROL_STATE_MAY_BE_CHANGED.json') $true 'restore_failure'
    Invoke-EntryCase 'fault-brightness-restore' {& (Join-Path $root 'scripts\start_maind_http_brightness_control_test.ps1') -EnableBrightnessExperiment -ConfirmToken I_APPROVE_SMALL_BRIGHTNESS_CHANGE_AND_RESTORE -AllowTemporaryOn -TemporaryOnConfirmToken I_APPROVE_TEMPORARY_ON_AND_RESTORE -SshAlias mock -StationIPv4 127.0.0.1 -StationIPv6 ::1 -MatterNodeId 258 -MatterEndpointId 1} @('controller_error.txt','LIGHT_STATE_MAY_BE_CHANGED.json') $true 'restore_failure'
    foreach($fault in @('visual_color_fail_after_on','visual_color_fail_after_level','visual_color_fail_after_color','visual_color_fail_color_restore','visual_color_fail_level_restore','visual_color_fail_onoff_restore')){
        Invoke-EntryCase "fault-$fault" {& (Join-Path $root 'scripts\start_maind_http_color_visual_test.ps1') -EnableVisualColorExperiment -ConfirmToken I_APPROVE_VISUAL_COLOR_85_LEVEL_64_AND_RESTORE -AllowTemporaryOn -TemporaryOnConfirmToken I_APPROVE_TEMPORARY_ON_AND_RESTORE -SshAlias mock -StationIPv4 127.0.0.1 -StationIPv6 ::1 -MatterNodeId 258 -MatterEndpointId 1} @('controller_error.txt') $true $fault
        $state=Get-Content -Raw (Join-Path $env:MAIND_MOCK_ROOT 'state.json')|ConvertFrom-Json
        Assert-True (-not$state.onoff-and$state.level-eq4-and$state.hue-eq159-and$state.saturation-eq244) "watchdog restore mismatch after $fault"
    }
}finally{
    $env:WINDIR=$oldWindir;$env:MAIND_MOCK_ROOT=$oldRoot;$env:MAIND_MOCK_PYTHON=$oldPython;$env:MAIND_MOCK_SSH_SCRIPT=$oldScript;$env:MAIND_MOCK_FAULT=$oldFault;$env:MAIND_MOCK_INITIAL_ON=$oldInitialOn
}

$failed=@($cases|Where-Object status -eq FAIL)
$summary=[ordered]@{generated_utc=[DateTime]::UtcNow.ToString('o');powershell_version=$PSVersionTable.PSVersion.ToString();all_pass=($failed.Count-eq0);case_count=$cases.Count;failed_count=$failed.Count;cases=@($cases)}
$summary|ConvertTo-Json -Depth 10|Set-Content -Encoding UTF8 (Join-Path $OutputDirectory 'offline_harness_results.json')
if($failed.Count){throw "Full controller audit harness failed $($failed.Count) cases"}
"FULL_CONTROLLER_OFFLINE_HARNESS=PASS`nRESULTS=$OutputDirectory"
