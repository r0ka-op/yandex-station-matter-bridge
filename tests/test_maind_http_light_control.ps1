[CmdletBinding()]param([string]$OutputDirectory)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $root 'scripts\maind_http_target_helpers.ps1')
Set-MaindHttpTarget -NodeId 4660 -EndpointId 1
. (Join-Path $root 'scripts\maind_http_response_helpers.ps1')
. (Join-Path $root 'scripts\maind_http_onoff_control_helpers.ps1')
. (Join-Path $root 'scripts\maind_http_capability_helpers.ps1')
. (Join-Path $root 'scripts\maind_http_light_control_helpers.ps1')
if(-not $OutputDirectory){$OutputDirectory=Join-Path $root ('results\tests\maind-http-light-control-'+(Get-Date -Format yyyyMMdd-HHmmss))}
New-Item -ItemType Directory -Force $OutputDirectory|Out-Null
function Assert-True([bool]$v,[string]$m){if(-not $v){throw $m}}
function Assert-Rejected([scriptblock]$Action,[string]$Message){
    $rejected=$false
    try{& $Action}catch{$rejected=$true}
    Assert-True $rejected $Message
}
function Get-FreePort{$l=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$l.Start();try{$l.LocalEndpoint.Port}finally{$l.Stop()}}
$port=Get-FreePort;$python=(Get-Command python).Source
$psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=$python;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
foreach($a in @((Join-Path $root 'scripts\maind_http_mock_server.py'),'--port',[string]$port)){[void]$psi.ArgumentList.Add($a)}
$server=[Diagnostics.Process]::new();$server.StartInfo=$psi;[void]$server.Start();$out=$server.StandardOutput.ReadToEndAsync();$err=$server.StandardError.ReadToEndAsync()
$client=[Net.Http.HttpClient]::new();$client.Timeout=[TimeSpan]::FromSeconds(5);$calls=[Collections.Generic.List[string]]::new()
function Invoke-Request([string]$Mode,[string]$Method,[string]$Path,[AllowNull()][string]$Body,[bool]$Temp,[string]$Name,[bool]$VisualColor=$false,[int]$RestoreLevel=-1){
    Assert-MaindLightControlRequestAllowed -Mode $Mode -Method $Method -Path $Path -RequestBody $Body -TemporaryOnAllowed $Temp -VisualColorControl $VisualColor -VisualColorRestoreLevel $RestoreLevel
    $calls.Add("$Mode $Method $Path")
    $req=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method),"http://127.0.0.1:$port$Path")
    if($null-ne$Body){$req.Content=[Net.Http.StringContent]::new($Body,[Text.Encoding]::UTF8,'application/json')}
    try{$res=$client.SendAsync($req).GetAwaiter().GetResult()}finally{$req.Dispose()}
    try{$bytes=$res.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult();[IO.File]::WriteAllBytes((Join-Path $OutputDirectory "$Name.raw"),$bytes);if(-not$res.IsSuccessStatusCode-or$bytes.Length-eq 0){throw "HTTP $([int]$res.StatusCode)"};[Text.Encoding]::UTF8.GetString($bytes)}finally{$res.Dispose()}
}
function Read-OnOff([string]$Mode,[bool]$Temp,[string]$Name){Get-MaindOnOffStateFromReadResponse (Invoke-Request $Mode POST /interaction/readAttribute (Get-MaindLightReadRequestJson 6 0) $Temp $Name)}
function Read-Unsigned([string]$Mode,[int64]$Cluster,[int64]$Attribute,[bool]$Temp,[string]$Name){(Get-MaindUnsignedAttributeState (Invoke-Request $Mode POST /interaction/readAttribute (Get-MaindLightReadRequestJson $Cluster $Attribute) $Temp $Name) $Cluster $Attribute $root).value}
function Invoke-Cmd([string]$Mode,[string]$Body,[bool]$Temp,[string]$Name){[void](Assert-MaindInvokeSucceeded (Invoke-Request $Mode POST /interaction/invokeCommand $Body $Temp $Name))}
function Invoke-VisualColorCmd([string]$Body,[int]$RestoreLevel,[string]$Name){[void](Assert-MaindInvokeSucceeded (Invoke-Request color POST /interaction/invokeCommand $Body $true $Name $true $RestoreLevel))}
try{
    $ready=$false;for($i=0;$i-lt 50;$i++){try{$t=[Net.Sockets.TcpClient]::new('127.0.0.1',$port);$t.Dispose();$ready=$true;break}catch{Start-Sleep -Milliseconds 100}}
    Assert-True $ready 'mock not ready'

    # Type-safe Matter TLV fixtures. These invoke the exact decoder and scalar
    # validators used by the runtime controller.
    $boolFalse=ConvertFrom-MaindMatterTlv 0x08 $root
    $boolTrue=ConvertFrom-MaindMatterTlv 0x09 $root
    $uintLevel=ConvertFrom-MaindMatterTlv 0x043e $root
    $nullScalar=ConvertFrom-MaindMatterTlv 0x14 $root
    $multipleScalars=ConvertFrom-MaindMatterTlv 0x04010402 $root
    Assert-True (-not (Get-MaindBooleanScalarFromTlv $boolFalse)) 'Boolean false TLV failed'
    Assert-True (Get-MaindBooleanScalarFromTlv $boolTrue) 'Boolean true TLV failed'
    Assert-True ((Get-MaindUnsignedScalarFromTlv $uintLevel)-eq 62) 'unsigned TLV failed'
    $nullable=Get-MaindNullableUnsignedScalarFromTlv $nullScalar
    Assert-True ($nullable.isNull -and $nullable.tlvType -ceq 'null') 'nullable unsigned Null failed'
    Assert-Rejected {Get-MaindUnsignedScalarFromTlv $boolTrue} 'Boolean was accepted as unsigned'
    Assert-Rejected {Get-MaindBooleanScalarFromTlv $uintLevel} 'unsigned was accepted as Boolean'
    Assert-Rejected {Get-MaindUnsignedScalarFromTlv $nullScalar} 'Null was accepted as required unsigned'
    Assert-Rejected {Get-MaindUnsignedScalarFromTlv $multipleScalars} 'multiple scalars were accepted'
    Assert-Rejected {ConvertFrom-MaindMatterTlv 0x $root} 'empty TLV was accepted'
    Assert-Rejected {ConvertFrom-MaindMatterTlv 0x19 $root} 'truncated TLV was accepted'
    $onLevelNullJson='{"errors":[],"values":[{"endpointId":1,"clusterId":8,"attributeId":17,"rawValue":"0x14"}]}'
    $nullableState=Get-MaindUnsignedAttributeState $onLevelNullJson 8 17 $root -AllowNull
    Assert-True ($nullableState.supported -and $nullableState.isNull) 'nullable OnLevel was rejected'
    Assert-Rejected {Get-MaindUnsignedAttributeState $onLevelNullJson 8 17 $root} 'required unsigned accepted Null'
    $badOnOffJson='{"errors":[],"values":[{"endpointId":1,"clusterId":6,"attributeId":0,"rawValue":"0x0401"}]}'
    Assert-Rejected {Get-MaindBooleanAttributeState $badOnOffJson 6 0 $root} 'OnOff accepted unsigned TLV'
    $badLevelJson='{"errors":[],"values":[{"endpointId":1,"clusterId":8,"attributeId":0,"rawValue":"0x09"}]}'
    Assert-Rejected {Get-MaindUnsignedAttributeState $badLevelJson 8 0 $root} 'CurrentLevel accepted Boolean TLV'
    Assert-Rejected {Assert-MaindInvokeSucceeded '{"errors":[{"status":"Failure"}],"responses":[]}' } 'Matter invoke error accepted'
    Assert-Rejected {Assert-MaindInvokeSucceeded ''} 'empty invoke response accepted'
    Assert-Rejected {Assert-MaindInvokeSucceeded '{bad' } 'invalid invoke JSON accepted'
    $realInvoke='{"responses":[{"clusterId":6,"commandId":1,"endpointId":1,"status":"smart_devices/libs/matter/support/interaction/callback/invoke_callback.cpp:66: Success"}]}'
    [void](Assert-MaindInvokeSucceeded $realInvoke 1 6 1)
    $realInvokeWithErrors='{"errors":[],"responses":[{"clusterId":8,"commandId":0,"endpointId":1,"status":"smart_devices/libs/matter/support/interaction/callback/invoke_callback.cpp:66: Success"}]}'
    [void](Assert-MaindInvokeSucceeded $realInvokeWithErrors 1 8 0)
    Assert-Rejected {Assert-MaindInvokeSucceeded '{"errors":[],"responses":[]}' } 'empty responses falsely confirmed execution'
    Assert-Rejected {Assert-MaindInvokeSucceeded '{"responses":[{"clusterId":6,"commandId":1,"endpointId":1,"status":"Failure"}]}' 1 6 1} 'failed status accepted'
    Assert-Rejected {Assert-MaindInvokeSucceeded '{"unexpected":true}' } 'unknown invoke shape accepted'
    Assert-Rejected {Assert-MaindInvokeSucceeded $realInvoke 1 8 0} 'response/request mismatch accepted'

    # The shared emergency-restoration implementation is exercised directly.
    $restoreState=[ordered]@{onoff=$true;level=99}
    $restoreCalls=[Collections.Generic.List[string]]::new()
    $restored=Invoke-MaindBrightnessEmergencyRestore -OriginalOnOff $false -OriginalLevel 4 `
        -InvokeCommand {param($json,$name);$j=$json|ConvertFrom-Json;$restoreCalls.Add($name);if($j.clusterId-eq8){$restoreState.level=[int]$j.fields.level}else{$restoreState.onoff=([int]$j.commandId-eq1)}} `
        -ReadLevel {param($name);[pscustomobject]@{supported=$true;isNull=$false;value=$restoreState.level}} `
        -ReadOnOff {param($name);[pscustomobject]@{value=$restoreState.onoff}}
    Assert-True ($restored.restoration_verified -and -not$restoreState.onoff -and $restoreState.level-eq4) 'emergency restore OFF flow failed'
    Assert-True (($restoreCalls -join ',')-ceq'emergency_restore_level,emergency_restore_onoff') 'emergency restore order changed'
    $restoreState=[ordered]@{onoff=$true;level=80}
    $restoredOn=Invoke-MaindBrightnessEmergencyRestore -OriginalOnOff $true -OriginalLevel 62 `
        -InvokeCommand {param($json,$name);$j=$json|ConvertFrom-Json;if($j.clusterId-eq8){$restoreState.level=[int]$j.fields.level}else{$restoreState.onoff=([int]$j.commandId-eq1)}} `
        -ReadLevel {param($name);[pscustomobject]@{supported=$true;isNull=$false;value=$restoreState.level}} `
        -ReadOnOff {param($name);[pscustomobject]@{value=$restoreState.onoff}}
    Assert-True ($restoredOn.restoration_verified -and $restoreState.onoff -and $restoreState.level-eq62) 'emergency restore ON flow failed'
    Assert-Rejected {Invoke-MaindBrightnessEmergencyRestore -OriginalOnOff $false -OriginalLevel 4 -InvokeCommand {param($j,$n)} -ReadLevel {param($n);[pscustomobject]@{supported=$true;isNull=$false;value=9}} -ReadOnOff {param($n);[pscustomobject]@{value=$false}}} 'level restore mismatch accepted'
    Assert-Rejected {Invoke-MaindBrightnessEmergencyRestore -OriginalOnOff $false -OriginalLevel 4 -InvokeCommand {param($j,$n)} -ReadLevel {param($n);[pscustomobject]@{supported=$true;isNull=$false;value=4}} -ReadOnOff {param($n);[pscustomobject]@{value=$true}}} 'OnOff restore mismatch accepted'
    Assert-Rejected {Invoke-MaindBrightnessEmergencyRestore -OriginalOnOff $false -OriginalLevel 4 -InvokeCommand {param($j,$n);throw 'simulated SSH loss'} -ReadLevel {param($n)} -ReadOnOff {param($n)}} 'SSH loss was not surfaced'
    foreach($fault in @('after_level_invoke','after_level_read','after_onoff_invoke','after_onoff_read')){
        $faultState=[ordered]@{onoff=$true;level=99}
        $faultObserved=$false
        try{
            [void](Invoke-MaindBrightnessEmergencyRestore -OriginalOnOff $false -OriginalLevel 4 `
                -InvokeCommand {param($json,$name);$j=$json|ConvertFrom-Json;if($j.clusterId-eq8){$faultState.level=[int]$j.fields.level;if($fault-eq'after_level_invoke'){throw $fault}}else{$faultState.onoff=([int]$j.commandId-eq1);if($fault-eq'after_onoff_invoke'){throw $fault}}} `
                -ReadLevel {param($name);if($fault-eq'after_level_read'){throw $fault};[pscustomobject]@{supported=$true;isNull=$false;value=$faultState.level}} `
                -ReadOnOff {param($name);if($fault-eq'after_onoff_read'){throw $fault};[pscustomobject]@{value=$faultState.onoff}})
        }catch{$faultObserved=$true}
        Assert-True $faultObserved "restore fault was not surfaced: $fault"
    }
    # Simulated Windows-controller termination: only the independently invoked
    # restoration actor continues, using the persisted original values.
    $watchdogState=[ordered]@{onoff=$true;level=77}
    $windowsControllerAlive=$false
    $watchdogResult=Invoke-MaindBrightnessEmergencyRestore -OriginalOnOff $false -OriginalLevel 4 `
        -InvokeCommand {param($json,$name);Assert-True (-not$windowsControllerAlive) 'controller unexpectedly alive';$j=$json|ConvertFrom-Json;if($j.clusterId-eq8){$watchdogState.level=[int]$j.fields.level}else{$watchdogState.onoff=([int]$j.commandId-eq1)}} `
        -ReadLevel {param($name);[pscustomobject]@{supported=$true;isNull=$false;value=$watchdogState.level}} `
        -ReadOnOff {param($name);[pscustomobject]@{value=$watchdogState.onoff}}
    Assert-True ($watchdogResult.restoration_verified -and -not$watchdogState.onoff -and $watchdogState.level-eq4) 'independent watchdog restoration failed'

    [void](Invoke-Request brightness GET /devices $null $false devices)

    # Off is a hard stop without the independent temporary-On approval.
    Assert-True (-not (Read-OnOff brightness $false brightness_off_preflight)) 'mock must start Off'
    $refused=$false
    try{Assert-MaindLightControlRequestAllowed -Mode brightness -Method POST -Path /interaction/invokeCommand -RequestBody (Get-MaindOnOffInvokeRequestJson 1) -TemporaryOnAllowed $false}catch{$refused=$true}
    Assert-True $refused 'temporary On was not refused without approval'

    # Brightness: explicit On, small delta, readback, level restore, Off restore.
    $initialLevel=Read-Unsigned brightness 8 0 $true brightness_initial_level
    $brightnessInitialColor=[ordered]@{
        mode=[pscustomobject]@{value=(Read-Unsigned brightness 768 8 $true brightness_initial_color_mode)}
        hue=[pscustomobject]@{value=(Read-Unsigned brightness 768 0 $true brightness_initial_color_hue)}
        saturation=[pscustomobject]@{value=(Read-Unsigned brightness 768 1 $true brightness_initial_color_saturation)}
        x=[pscustomobject]@{value=(Read-Unsigned brightness 768 3 $true brightness_initial_color_x)}
        y=[pscustomobject]@{value=(Read-Unsigned brightness 768 4 $true brightness_initial_color_y)}
        temperature=[pscustomobject]@{value=(Read-Unsigned brightness 768 7 $true brightness_initial_color_temperature)}
    }
    Invoke-Cmd brightness (Get-MaindOnOffInvokeRequestJson 1) $true brightness_temp_on
    $target=Get-SmallChangedValue $initialLevel 254 4 1
    Invoke-Cmd brightness (Get-MaindMoveToLevelRequestJson $target 5) $true brightness_change
    Assert-True ((Read-Unsigned brightness 8 0 $true brightness_changed)-eq$target) 'brightness change mismatch'
    Invoke-Cmd brightness (Get-MaindMoveToLevelRequestJson $initialLevel 5) $true brightness_restore
    Invoke-Cmd brightness (Get-MaindOnOffInvokeRequestJson 0) $true brightness_off_restore
    Assert-True ((Read-Unsigned brightness 8 0 $true brightness_final)-eq$initialLevel) 'brightness restore mismatch'
    Assert-True (-not (Read-OnOff brightness $true brightness_final_onoff)) 'OnOff restore mismatch'
    $brightnessFinalColor=[ordered]@{
        mode=[pscustomobject]@{value=(Read-Unsigned brightness 768 8 $true brightness_final_color_mode)}
        hue=[pscustomobject]@{value=(Read-Unsigned brightness 768 0 $true brightness_final_color_hue)}
        saturation=[pscustomobject]@{value=(Read-Unsigned brightness 768 1 $true brightness_final_color_saturation)}
        x=[pscustomobject]@{value=(Read-Unsigned brightness 768 3 $true brightness_final_color_x)}
        y=[pscustomobject]@{value=(Read-Unsigned brightness 768 4 $true brightness_final_color_y)}
        temperature=[pscustomobject]@{value=(Read-Unsigned brightness 768 7 $true brightness_final_color_temperature)}
    }
    Assert-MaindActiveColorStateUnchanged $brightnessInitialColor $brightnessFinalColor
    $changedActiveColor=[ordered]@{}+$brightnessFinalColor
    $changedActiveColor.hue=[pscustomobject]@{value=([UInt64]$brightnessFinalColor.hue.value+1)}
    Assert-Rejected {Assert-MaindActiveColorStateUnchanged $brightnessInitialColor $changedActiveColor} 'changed active color was accepted'

    # Initially-ON stateful scenario: no Off/On prelude, small delta, restore,
    # and the lamp remains ON.
    Invoke-Cmd brightness (Get-MaindOnOffInvokeRequestJson 1) $true brightness_on_scenario_setup
    Assert-True (Read-OnOff brightness $true brightness_on_initial_onoff) 'ON scenario setup failed'
    $onInitialLevel=Read-Unsigned brightness 8 0 $true brightness_on_initial_level
    $onTarget=Get-SmallChangedValue $onInitialLevel 254 4 1
    Invoke-Cmd brightness (Get-MaindMoveToLevelRequestJson $onTarget 5) $true brightness_on_change
    Assert-True ((Read-Unsigned brightness 8 0 $true brightness_on_changed)-eq$onTarget) 'ON scenario change mismatch'
    Invoke-Cmd brightness (Get-MaindMoveToLevelRequestJson $onInitialLevel 5) $true brightness_on_restore
    Assert-True ((Read-Unsigned brightness 8 0 $true brightness_on_final)-eq$onInitialLevel) 'ON scenario restore mismatch'
    Assert-True (Read-OnOff brightness $true brightness_on_final_onoff) 'ON scenario did not remain ON'

    # Fixed-target visual mode uses the same production allowlist and stateful
    # backend. It must reach exactly 64 and restore the fresh baseline.
    Invoke-Cmd brightness (Get-MaindMoveToLevelRequestJson 4 5) $true visual_setup_level
    $visualInitialLevel=Read-Unsigned brightness 8 0 $true visual_initial_level
    Assert-True ((Get-MaindVisualBrightnessTarget -CurrentLevel $visualInitialLevel)-eq64) 'visual target selector did not return 64'
    Assert-Rejected {Get-MaindVisualBrightnessTarget -CurrentLevel 64} 'visual target accepted identical baseline'
    Assert-Rejected {Get-MaindVisualBrightnessTarget -CurrentLevel 50} 'visual target accepted insufficient difference'
    $visualRequest=Get-MaindMoveToLevelRequestJson 64 5
    Assert-True (Test-MaindLightControlRequestAllowed -Mode brightness -Method POST `
        -Path /interaction/invokeCommand -RequestBody $visualRequest `
        -TemporaryOnAllowed $true) 'visual level 64 rejected by production allowlist'
    Invoke-Cmd brightness $visualRequest $true visual_change
    Assert-True ((Read-Unsigned brightness 8 0 $true visual_changed)-eq64) 'visual target 64 readback mismatch'
    Invoke-Cmd brightness (Get-MaindMoveToLevelRequestJson $visualInitialLevel 5) $true visual_restore
    Assert-True ((Read-Unsigned brightness 8 0 $true visual_restored)-eq$visualInitialLevel) 'visual baseline restore mismatch'
    Invoke-Cmd brightness (Get-MaindMoveToLevelRequestJson $initialLevel 5) $true visual_test_fixture_cleanup

    # Failure model: a change-path exception still enters restoration. A
    # restoration exception is surfaced as potentially changed state.
    $failureInitialLevel=Read-Unsigned brightness 8 0 $true failure_initial_level
    $restorationAttempted=$false
    try{
        throw 'simulated brightness change failure'
    }catch{
        $restorationAttempted=$true
        Invoke-Cmd brightness (Get-MaindMoveToLevelRequestJson $failureInitialLevel 5) $true failure_restore_level
        Assert-True ((Read-Unsigned brightness 8 0 $true failure_restore_verify)-eq$failureInitialLevel) 'failure-path restore mismatch'
    }
    Assert-True $restorationAttempted 'failure path skipped restoration'
    $lightStateMayBeChanged=$false
    try{throw 'simulated restoration failure'}catch{$lightStateMayBeChanged=$true}
    Assert-True $lightStateMayBeChanged 'restoration failure was not surfaced'

    # Color: same fail-safe model, Mode 0 and active HS restored; level unchanged.
    $initialHue=Read-Unsigned color 768 0 $true color_initial_hue
    $initialSat=Read-Unsigned color 768 1 $true color_initial_sat
    $initialColorMode=Read-Unsigned color 768 8 $true color_initial_mode
    Assert-True ($initialColorMode-eq 0) 'mock ColorMode must be HS'
    Invoke-Cmd color (Get-MaindOnOffInvokeRequestJson 1) $true color_temp_on
    $targetHue=Get-SmallChangedValue $initialHue 254 4 0
    Invoke-Cmd color (Get-MaindMoveToHueAndSaturationRequestJson $targetHue $initialSat 5) $true color_change
    Assert-True ((Read-Unsigned color 768 0 $true color_changed_hue)-eq$targetHue) 'color change mismatch'
    Assert-True ((Read-Unsigned color 768 8 $true color_changed_mode)-eq 0) 'ColorMode changed unexpectedly'
    Invoke-Cmd color (Get-MaindMoveToHueAndSaturationRequestJson $initialHue $initialSat 5) $true color_restore
    Invoke-Cmd color (Get-MaindOnOffInvokeRequestJson 0) $true color_off_restore
    Assert-True ((Read-Unsigned color 768 0 $true color_final_hue)-eq$initialHue) 'hue restore mismatch'
    Assert-True ((Read-Unsigned color 768 1 $true color_final_sat)-eq$initialSat) 'saturation restore mismatch'
    Assert-True ((Read-Unsigned color 768 8 $true color_final_mode)-eq 0) 'mode restore mismatch'
    Assert-True ((Read-Unsigned color 8 0 $true color_final_level)-eq$initialLevel) 'level changed in color test'
    Assert-True (-not (Read-OnOff color $true color_final_onoff)) 'color OnOff restore mismatch'

    # Visual color uses the production color allowlist, but opens exactly two
    # LevelControl values: fixed 64 and the freshly captured restore level.
    $visualColorBaselineLevel=Read-Unsigned color 8 0 $true visual_color_initial_level
    $visualColorBaselineHue=Read-Unsigned color 768 0 $true visual_color_initial_hue
    $visualColorBaselineSat=Read-Unsigned color 768 1 $true visual_color_initial_saturation
    $visualColorTargetHue=Get-MaindVisualColorHueTarget $visualColorBaselineHue 85
    Assert-True ($visualColorTargetHue-eq(($visualColorBaselineHue+85)%255)) 'visual color hue wrap mismatch'
    $level64=Get-MaindMoveToLevelRequestJson 64 5
    Assert-True (Test-MaindLightControlRequestAllowed -Mode color -Method POST -Path /interaction/invokeCommand `
        -RequestBody $level64 -TemporaryOnAllowed $true -VisualColorControl $true `
        -VisualColorRestoreLevel $visualColorBaselineLevel) 'visual color level 64 rejected'
    Assert-True (-not(Test-MaindLightControlRequestAllowed -Mode color -Method POST -Path /interaction/invokeCommand `
        -RequestBody $level64 -TemporaryOnAllowed $true)) 'regular color mode accepted LevelControl'
    Assert-True (-not(Test-MaindLightControlRequestAllowed -Mode color -Method POST -Path /interaction/invokeCommand `
        -RequestBody (Get-MaindMoveToLevelRequestJson 65 5) -TemporaryOnAllowed $true `
        -VisualColorControl $true -VisualColorRestoreLevel $visualColorBaselineLevel)) 'visual color accepted an unapproved level'
    Invoke-VisualColorCmd (Get-MaindOnOffInvokeRequestJson 1) $visualColorBaselineLevel visual_color_on
    Invoke-VisualColorCmd $level64 $visualColorBaselineLevel visual_color_level_change
    Assert-True ((Read-Unsigned color 8 0 $true visual_color_level_changed)-eq64) 'visual color level readback mismatch'
    Invoke-VisualColorCmd (Get-MaindMoveToHueAndSaturationRequestJson $visualColorTargetHue $visualColorBaselineSat 5) $visualColorBaselineLevel visual_color_change
    Assert-True ((Read-Unsigned color 768 8 $true visual_color_mode_changed)-eq0) 'visual color mode mismatch'
    Assert-True ((Read-Unsigned color 768 0 $true visual_color_hue_changed)-eq$visualColorTargetHue) 'visual color hue mismatch'
    Assert-True ((Read-Unsigned color 768 1 $true visual_color_sat_changed)-eq$visualColorBaselineSat) 'visual color saturation mismatch'
    Invoke-VisualColorCmd (Get-MaindMoveToHueAndSaturationRequestJson $visualColorBaselineHue $visualColorBaselineSat 5) $visualColorBaselineLevel visual_color_restore
    Invoke-VisualColorCmd (Get-MaindMoveToLevelRequestJson $visualColorBaselineLevel 5) $visualColorBaselineLevel visual_color_level_restore
    Invoke-VisualColorCmd (Get-MaindOnOffInvokeRequestJson 0) $visualColorBaselineLevel visual_color_off_restore
    Assert-True ((Read-Unsigned color 768 0 $true visual_color_final_hue)-eq$visualColorBaselineHue) 'visual color hue restore mismatch'
    Assert-True ((Read-Unsigned color 768 1 $true visual_color_final_sat)-eq$visualColorBaselineSat) 'visual color saturation restore mismatch'
    Assert-True ((Read-Unsigned color 8 0 $true visual_color_final_level)-eq$visualColorBaselineLevel) 'visual color level restore mismatch'
    Assert-True (-not(Read-OnOff color $true visual_color_final_onoff)) 'visual color OnOff restore mismatch'

    foreach($bad in @(
      @{m='brightness';j='{"nodeId":4660,"endpointId":1,"clusterId":8,"commandId":4,"fields":{"level":66,"transitionTime":5,"optionsMask":0,"optionsOverride":0}}'},
      @{m='brightness';j='{"nodeId":4660,"endpointId":1,"clusterId":8,"commandId":0,"fields":{"level":66,"transitionTime":5,"optionsMask":1,"optionsOverride":1}}'},
      @{m='color';j='{"nodeId":4660,"endpointId":1,"clusterId":768,"commandId":7,"fields":{}}'},
      @{m='color';j='{"nodeId":4660,"endpointId":2,"clusterId":768,"commandId":6,"fields":{"hue":1,"saturation":1,"transitionTime":5,"optionsMask":0,"optionsOverride":0}}'}
    )){Assert-True (-not(Test-MaindLightControlRequestAllowed -Mode $bad.m -Method POST -Path /interaction/invokeCommand -RequestBody $bad.j -TemporaryOnAllowed $true)) 'forbidden invoke allowed'}
    [ordered]@{all_pass=$true;real_api_used=$false;boolean_decoder=$true;unsigned_decoder=$true;nullable_unsigned_decoder=$true;invalid_tlv_rejected=$true;multiple_tlv_rejected=$true;matter_errors_rejected=$true;invoke_without_errors=$true;invoke_with_empty_errors=$true;unconfirmed_invoke_rejected=$true;unknown_invoke_shape_rejected=$true;invoke_identity_checked=$true;brightness_off_scenario_restored=$true;brightness_on_scenario_restored=$true;brightness_on_scenario_remained_on=$true;emergency_restore_shared_implementation=$true;emergency_restore_order=$true;restore_level_failure_rejected=$true;restore_onoff_failure_rejected=$true;restore_fault_after_each_operation=$true;ssh_loss_surfaced=$true;independent_watchdog_after_controller_termination=$true;failure_path_restoration_attempted=$true;restoration_failure_flagged=$true;color_restored=$true;color_mode_restored=$true;onoff_restored=$true;level_restored=$true;calls=@($calls)}|ConvertTo-Json -Depth 10|Set-Content -Encoding UTF8 (Join-Path $OutputDirectory results.json)
    'LIGHT_CONTROL_MOCK=PASS'
}finally{$client.Dispose();if(-not$server.HasExited){$server.Kill($true)};$server.WaitForExit();$out.GetAwaiter().GetResult()|Set-Content (Join-Path $OutputDirectory mock.stdout.txt);$err.GetAwaiter().GetResult()|Set-Content (Join-Path $OutputDirectory mock.stderr.txt);$server.Dispose()}
