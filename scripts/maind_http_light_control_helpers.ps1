Set-StrictMode -Version Latest

function Get-MaindLightReadRequestJson {
    param([UInt64]$ClusterId,[UInt64]$AttributeId)
    $target=Get-MaindHttpTarget
    ConvertTo-Json -Compress -InputObject ([ordered]@{
        nodeId=$target.NodeId; endpointId=$target.EndpointId; clusterId=$ClusterId; attributeId=$AttributeId
    })
}

function Get-MaindMoveToLevelRequestJson {
    param([ValidateRange(1,254)][int]$Level,[ValidateRange(0,65534)][int]$TransitionTime=5)
    $target=Get-MaindHttpTarget
    ConvertTo-Json -Compress -InputObject ([ordered]@{
        nodeId=$target.NodeId; endpointId=$target.EndpointId; clusterId=8; commandId=0
        fields=[ordered]@{level=$Level;transitionTime=$TransitionTime;optionsMask=0;optionsOverride=0}
    })
}

function Get-MaindMoveToHueAndSaturationRequestJson {
    param(
        [ValidateRange(0,254)][int]$Hue,
        [ValidateRange(0,254)][int]$Saturation,
        [ValidateRange(0,65534)][int]$TransitionTime=5
    )
    $target=Get-MaindHttpTarget
    ConvertTo-Json -Compress -InputObject ([ordered]@{
        nodeId=$target.NodeId; endpointId=$target.EndpointId; clusterId=768; commandId=6
        fields=[ordered]@{hue=$Hue;saturation=$Saturation;transitionTime=$TransitionTime;optionsMask=0;optionsOverride=0}
    })
}

function Test-MaindLightControlRequestAllowed {
    param(
        [ValidateSet('brightness','color')][string]$Mode,
        [string]$Method,[string]$Path,[AllowNull()][AllowEmptyString()][string]$RequestBody,
        [bool]$TemporaryOnAllowed=$false,
        [bool]$VisualColorControl=$false,
        [int]$VisualColorRestoreLevel=-1
    )
    if ($Method -ceq 'GET' -and $Path -ceq '/devices' -and [string]::IsNullOrEmpty($RequestBody)) { return $true }
    if ($Method -cne 'POST' -or [string]::IsNullOrEmpty($RequestBody)) { return $false }
    try {
        $target=Get-MaindHttpTarget
        $body=ConvertFrom-Json $RequestBody -NoEnumerate -ErrorAction Stop
        $names=@($body.PSObject.Properties.Name|Sort-Object)
        if ($Path -ceq '/interaction/readAttribute') {
            if (($names -join ',') -cne 'attributeId,clusterId,endpointId,nodeId' -or
                [UInt64]$body.nodeId -ne [UInt64]$target.NodeId -or
                [UInt64]$body.endpointId -ne [UInt64]$target.EndpointId) { return $false }
            $pair="$([UInt64]$body.clusterId)/$([UInt64]$body.attributeId)"
            $allowed = if ($Mode -ceq 'brightness') {
                @('6/0','8/0','8/15','8/16','8/17','768/0','768/1','768/3','768/4','768/7','768/8')
            } else {
                @('6/0','8/0','768/0','768/1','768/3','768/4','768/7','768/8')
            }
            return $pair -in $allowed
        }
        if ($Path -cne '/interaction/invokeCommand' -or
            ($names -join ',') -cne 'clusterId,commandId,endpointId,fields,nodeId' -or
            [UInt64]$body.nodeId -ne [UInt64]$target.NodeId -or
            [UInt64]$body.endpointId -ne [UInt64]$target.EndpointId) { return $false }
        if ([UInt64]$body.clusterId -eq 6 -and [int]$body.commandId -in @(0,1)) {
            return $TemporaryOnAllowed -and @($body.fields.PSObject.Properties).Count -eq 0
        }
        $fieldNames=@($body.fields.PSObject.Properties.Name|Sort-Object)
        if ([int]$body.fields.optionsMask -ne 0 -or [int]$body.fields.optionsOverride -ne 0 -or
            [int]$body.fields.transitionTime -ne 5) { return $false }
        if ($Mode -ceq 'brightness') {
            return ($fieldNames -join ',') -ceq 'level,optionsMask,optionsOverride,transitionTime' -and
                [UInt64]$body.clusterId -eq 8 -and [int]$body.commandId -eq 0 -and
                [int]$body.fields.level -ge 1 -and [int]$body.fields.level -le 254
        }
        if ([UInt64]$body.clusterId -eq 8 -and [int]$body.commandId -eq 0) {
            if (-not $VisualColorControl -or
                ($fieldNames -join ',') -cne 'level,optionsMask,optionsOverride,transitionTime') { return $false }
            $level=[int]$body.fields.level
            return $level -eq 64 -or ($VisualColorRestoreLevel -ge 1 -and $level -eq $VisualColorRestoreLevel)
        }
        return ($fieldNames -join ',') -ceq 'hue,optionsMask,optionsOverride,saturation,transitionTime' -and
            [UInt64]$body.clusterId -eq 768 -and [int]$body.commandId -eq 6 -and
            [int]$body.fields.hue -ge 0 -and [int]$body.fields.hue -le 254 -and
            [int]$body.fields.saturation -ge 0 -and [int]$body.fields.saturation -le 254
    } catch { return $false }
}

function Assert-MaindLightControlRequestAllowed {
    param(
        [ValidateSet('brightness','color')][string]$Mode,
        [string]$Method,[string]$Path,[AllowNull()][AllowEmptyString()][string]$RequestBody,
        [bool]$TemporaryOnAllowed=$false,
        [bool]$VisualColorControl=$false,
        [int]$VisualColorRestoreLevel=-1
    )
    if (-not (Test-MaindLightControlRequestAllowed @PSBoundParameters)) {
        throw "HTTP request is not allowlisted for $Mode control: $Method $Path"
    }
}

function Get-MaindUnsignedAttributeState {
    param(
        [string]$JsonText,[UInt64]$ClusterId,[UInt64]$AttributeId,[string]$Root,
        [switch]$AllowNull
    )
    $attribute=Get-MaindAttributeResult $JsonText $ClusterId $AttributeId
    if (-not $attribute.supported) { return [pscustomobject]@{supported=$false;errors=$attribute.errors} }
    $decoded=ConvertFrom-MaindMatterTlv ([string]$attribute.value.rawValue) $Root
    if ($AllowNull) {
        $scalar=Get-MaindNullableUnsignedScalarFromTlv $decoded
        return [pscustomobject]@{
            supported=$true;isNull=$scalar.isNull;value=$scalar.value
            tlvType=$scalar.tlvType;rawValue=[string]$attribute.value.rawValue
        }
    }
    $value=Get-MaindUnsignedScalarFromTlv $decoded
    $element=@($decoded.elements)[0]
    [pscustomobject]@{
        supported=$true;isNull=$false;value=$value;tlvType=[string]$element.type
        rawValue=[string]$attribute.value.rawValue
    }
}

function Get-MaindBooleanAttributeState {
    param([string]$JsonText,[UInt64]$ClusterId,[UInt64]$AttributeId,[string]$Root)
    $attribute=Get-MaindAttributeResult $JsonText $ClusterId $AttributeId
    if (-not $attribute.supported) { return [pscustomobject]@{supported=$false;errors=$attribute.errors} }
    $decoded=ConvertFrom-MaindMatterTlv ([string]$attribute.value.rawValue) $Root
    $value=Get-MaindBooleanScalarFromTlv $decoded
    $element=@($decoded.elements)[0]
    [pscustomobject]@{
        supported=$true;value=$value;tlvType=[string]$element.type
        rawValue=[string]$attribute.value.rawValue
    }
}

function Assert-MaindInvokeSucceeded {
    param(
        [string]$JsonText,
        [long]$ExpectedEndpointId=-1,
        [long]$ExpectedClusterId=-1,
        [long]$ExpectedCommandId=-1
    )
    if ([string]::IsNullOrWhiteSpace($JsonText)) { throw 'Matter invoke response body is empty' }
    $parsed=ConvertFrom-Json $JsonText -Depth 30 -NoEnumerate -ErrorAction Stop
    if ($parsed -isnot [Management.Automation.PSCustomObject] -and
        $parsed -isnot [Collections.IDictionary]) {
        throw 'Matter invoke response root must be an object'
    }
    $errorProperty=$parsed.PSObject.Properties['errors']
    if ($null -ne $errorProperty) {
        if ($null -eq $errorProperty.Value) { throw 'Matter invoke errors property is null' }
        if ($errorProperty.Value -isnot [Collections.IList]) { throw 'Matter invoke errors property must be an array' }
        $errors=@($errorProperty.Value)
        if ($errors.Count -ne 0) { throw 'Matter invoke returned errors' }
    }
    $responsesProperty=$parsed.PSObject.Properties['responses']
    if ($null -eq $responsesProperty -or $null -eq $responsesProperty.Value) {
        throw 'Matter invoke response has no responses array'
    }
    if ($responsesProperty.Value -isnot [Collections.IList]) {
        throw 'Matter invoke responses property must be an array'
    }
    $responses=@($responsesProperty.Value)
    if ($responses.Count -eq 0) { throw 'Matter invoke execution is unconfirmed: responses is empty' }
    foreach($response in $responses) {
        if ($response -isnot [Management.Automation.PSCustomObject]) {
            throw 'Matter invoke response entry must be an object'
        }
        foreach($required in @('endpointId','clusterId','commandId','status')) {
            if ($null -eq $response.PSObject.Properties[$required]) {
                throw "Matter invoke response entry lacks $required"
            }
        }
        if ([string]$response.status -notmatch '(^|:\s*)Success$') {
            throw "Matter invoke response status is not Success: $($response.status)"
        }
        if ($ExpectedEndpointId -ge 0 -and [long]$response.endpointId -ne $ExpectedEndpointId) {
            throw 'Matter invoke response endpoint mismatch'
        }
        if ($ExpectedClusterId -ge 0 -and [long]$response.clusterId -ne $ExpectedClusterId) {
            throw 'Matter invoke response cluster mismatch'
        }
        if ($ExpectedCommandId -ge 0 -and [long]$response.commandId -ne $ExpectedCommandId) {
            throw 'Matter invoke response command mismatch'
        }
    }
    return $parsed
}

function Invoke-MaindBrightnessEmergencyRestore {
    param(
        [bool]$OriginalOnOff,
        [ValidateRange(1,254)][int]$OriginalLevel,
        [Parameter(Mandatory=$true)][scriptblock]$InvokeCommand,
        [Parameter(Mandatory=$true)][scriptblock]$ReadLevel,
        [Parameter(Mandatory=$true)][scriptblock]$ReadOnOff
    )
    & $InvokeCommand (Get-MaindMoveToLevelRequestJson $OriginalLevel 5) 'emergency_restore_level'
    $levelState=& $ReadLevel 'emergency_restore_level_verify'
    if (-not $levelState.supported -or $levelState.isNull -or
        [UInt64]$levelState.value -ne [UInt64]$OriginalLevel) {
        throw 'Emergency brightness restoration readback mismatch'
    }
    $onOffCommand=if($OriginalOnOff){1}else{0}
    & $InvokeCommand (Get-MaindOnOffInvokeRequestJson $onOffCommand) 'emergency_restore_onoff'
    $onOffState=& $ReadOnOff 'emergency_restore_onoff_verify'
    if ([bool]$onOffState.value -ne $OriginalOnOff) {
        throw 'Emergency OnOff restoration readback mismatch'
    }
    [pscustomobject]@{
        restoration_verified=$true
        level=[UInt64]$levelState.value
        onoff=[bool]$onOffState.value
    }
}

function Get-SmallChangedValue {
    param([int]$Value,[int]$Maximum=254,[int]$Delta=4,[int]$Minimum=1)
    if ($Value + $Delta -le $Maximum) { return $Value + $Delta }
    if ($Value - $Delta -ge $Minimum) { return $Value - $Delta }
    throw 'No safe small delta available'
}

function Invoke-MaindBrightnessHold {
    param([ValidateRange(1,10)][int]$Seconds=3)
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $started=[DateTime]::UtcNow
    Start-Sleep -Seconds $Seconds
    $watch.Stop()
    [pscustomobject][ordered]@{
        started_utc=$started.ToString('o')
        completed_utc=[DateTime]::UtcNow.ToString('o')
        requested_seconds=$Seconds
        elapsed_ms=$watch.ElapsedMilliseconds
    }
}

function Get-MaindVisualColorHueTarget {
    param(
        [ValidateRange(0,254)][int]$CurrentHue,
        [ValidateRange(1,254)][int]$Delta=85
    )
    # Matter CurrentHue spans 255 values (0..254), so wrap modulo 255.
    return ($CurrentHue + $Delta) % 255
}

function Get-MaindVisualBrightnessTarget {
    param(
        [ValidateRange(1,254)][int]$CurrentLevel,
        [ValidateRange(1,254)][int]$TargetLevel=64,
        [ValidateRange(1,254)][int]$MinimumDifference=16
    )
    if([Math]::Abs($CurrentLevel-$TargetLevel)-lt$MinimumDifference){
        throw "CurrentLevel $CurrentLevel is too close to $TargetLevel for a visually distinct controlled test"
    }
    return $TargetLevel
}

function Assert-MaindActiveColorStateUnchanged {
    param($Initial,$Final)
    if ([UInt64]$Final.mode.value -ne [UInt64]$Initial.mode.value) {
        throw 'ColorMode changed during brightness control'
    }
    switch ([UInt64]$Initial.mode.value) {
        0 {
            if ([UInt64]$Final.hue.value -ne [UInt64]$Initial.hue.value -or
                [UInt64]$Final.saturation.value -ne [UInt64]$Initial.saturation.value) {
                throw 'Active Hue/Saturation state changed during brightness control'
            }
        }
        1 {
            if ([UInt64]$Final.x.value -ne [UInt64]$Initial.x.value -or
                [UInt64]$Final.y.value -ne [UInt64]$Initial.y.value) {
                throw 'Active XY state changed during brightness control'
            }
        }
        2 {
            if ([UInt64]$Final.temperature.value -ne [UInt64]$Initial.temperature.value) {
                throw 'Active color-temperature state changed during brightness control'
            }
        }
        default { throw "Unsupported ColorMode in brightness safety snapshot: $($Initial.mode.value)" }
    }
}
