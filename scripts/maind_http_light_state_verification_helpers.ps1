Set-StrictMode -Version Latest

function Get-MaindLightStateVerificationReadJson {
    param(
        [ValidateSet(6,8)][UInt64]$ClusterId,
        [ValidateSet(0)][UInt64]$AttributeId = 0
    )
    $target=Get-MaindHttpTarget
    ConvertTo-Json -Compress -InputObject ([ordered]@{
        nodeId=$target.NodeId; endpointId=$target.EndpointId; clusterId=$ClusterId; attributeId=$AttributeId
    })
}

function Test-MaindLightStateVerificationRequestAllowed {
    param(
        [string]$Method,
        [string]$Path,
        [AllowNull()][AllowEmptyString()][string]$RequestBody
    )
    if ($Method -ceq 'GET' -and $Path -ceq '/devices' -and
        [string]::IsNullOrEmpty($RequestBody)) { return $true }
    if ($Method -cne 'POST' -or $Path -cne '/interaction/readAttribute' -or
        [string]::IsNullOrWhiteSpace($RequestBody)) { return $false }
    try {
        $target=Get-MaindHttpTarget
        $body=ConvertFrom-Json $RequestBody -NoEnumerate -ErrorAction Stop
        $names=@($body.PSObject.Properties.Name|Sort-Object)
        if (($names -join ',') -cne 'attributeId,clusterId,endpointId,nodeId' -or
            [UInt64]$body.nodeId -ne [UInt64]$target.NodeId -or
            [UInt64]$body.endpointId -ne [UInt64]$target.EndpointId -or
            [UInt64]$body.attributeId -ne 0) { return $false }
        return [UInt64]$body.clusterId -in @(6,8)
    } catch { return $false }
}

function Assert-MaindLightStateVerificationRequestAllowed {
    param(
        [string]$Method,
        [string]$Path,
        [AllowNull()][AllowEmptyString()][string]$RequestBody
    )
    if (-not (Test-MaindLightStateVerificationRequestAllowed @PSBoundParameters)) {
        throw "HTTP request is not allowlisted for light-state verification: $Method $Path"
    }
}

function Compare-MaindLightStateWithExpected {
    param(
        [bool]$ActualOnOff,
        [UInt64]$ActualLevel,
        [bool]$ExpectedOnOff = $false,
        [UInt64]$ExpectedLevel = 4
    )
    $onMatch=$ActualOnOff -eq $ExpectedOnOff
    $levelMatch=$ActualLevel -eq $ExpectedLevel
    [pscustomobject][ordered]@{
        expected=[ordered]@{onOff=$ExpectedOnOff;currentLevel=$ExpectedLevel}
        actual=[ordered]@{onOff=$ActualOnOff;currentLevel=$ActualLevel}
        onoff_matches=$onMatch
        current_level_matches=$levelMatch
        light_state_verified=($onMatch -and $levelMatch)
    }
}
