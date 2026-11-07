Set-StrictMode -Version Latest

function Get-MaindOnOffInvokeRequestJson {
    param([Parameter(Mandatory = $true)][ValidateSet(0, 1)][int]$CommandId)
    $target=Get-MaindHttpTarget
    return (ConvertTo-Json -Compress -InputObject ([ordered]@{
        nodeId = $target.NodeId
        endpointId = $target.EndpointId
        clusterId = 6
        commandId = $CommandId
        fields = [ordered]@{}
    }))
}

function Test-MaindOnOffControlRequestAllowed {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()][AllowEmptyString()][string]$RequestBody
    )

    if (Test-MaindHttpRequestAllowed -Method $Method -Path $Path `
        -RequestBody $RequestBody -ReadOnOffAttributeEnabled $true) {
        return $true
    }
    if ($Method -cne 'POST' -or $Path -cne '/interaction/invokeCommand' -or
        [string]::IsNullOrEmpty($RequestBody)) { return $false }
    try {
        $target=Get-MaindHttpTarget
        $value = ConvertFrom-Json -InputObject $RequestBody -NoEnumerate -ErrorAction Stop
        $properties = @($value.PSObject.Properties)
        if ($properties.Count -ne 5) { return $false }
        if ((@($properties.Name | Sort-Object) -join ',') -cne
            'clusterId,commandId,endpointId,fields,nodeId') { return $false }
        if ([UInt64]$value.nodeId -ne [UInt64]$target.NodeId -or
            [UInt64]$value.endpointId -ne [UInt64]$target.EndpointId -or
            [UInt64]$value.clusterId -ne 6 -or [int]$value.commandId -notin @(0, 1)) {
            return $false
        }
        return (@($value.fields.PSObject.Properties).Count -eq 0)
    } catch { return $false }
}

function Assert-MaindOnOffControlRequestAllowed {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()][AllowEmptyString()][string]$RequestBody
    )
    if (-not (Test-MaindOnOffControlRequestAllowed -Method $Method -Path $Path `
        -RequestBody $RequestBody)) {
        throw "HTTP request is not allowlisted for the OnOff control test: $Method $Path"
    }
}

function Get-MaindOnOffStateFromReadResponse {
    param([Parameter(Mandatory = $true)][string]$JsonText)
    if ([string]::IsNullOrWhiteSpace($JsonText)) { throw 'Matter OnOff read response body is empty' }
    $parsed = ConvertFrom-Json -InputObject $JsonText -Depth 30 -NoEnumerate -ErrorAction Stop
    if ($parsed -isnot [Management.Automation.PSCustomObject]) {
        throw 'Matter OnOff read response root must be an object'
    }
    $errorsProperty=$parsed.PSObject.Properties['errors']
    if($null -eq $errorsProperty){throw 'Matter OnOff read response lacks errors property'}
    if($null -eq $errorsProperty.Value){throw 'Matter OnOff errors property is null'}
    if($errorsProperty.Value -isnot [Collections.IList]){throw 'Matter OnOff errors property must be an array'}
    $errors = @($errorsProperty.Value)
    if ($errors.Count -ne 0) { throw "Matter read returned errors" }
    $valuesProperty=$parsed.PSObject.Properties['values']
    if($null -eq $valuesProperty -or $null -eq $valuesProperty.Value){
        throw 'Matter OnOff read response lacks values array'
    }
    if($valuesProperty.Value -isnot [Collections.IList]){throw 'Matter OnOff values property must be an array'}
    $target=Get-MaindHttpTarget
    $matches = @(@($valuesProperty.Value) | Where-Object {
        if($_ -isnot [Management.Automation.PSCustomObject]){return $false}
        foreach($required in @('endpointId','clusterId','attributeId')){
            if($null -eq $_.PSObject.Properties[$required]){return $false}
        }
        [UInt64]$_.endpointId -eq [UInt64]$target.EndpointId -and [UInt64]$_.clusterId -eq 6 -and
            [UInt64]$_.attributeId -eq 0
    })
    if ($matches.Count -ne 1) { throw "Expected exactly one target endpoint / cluster 6 / attribute 0 value" }
    $rawProperty=$matches[0].PSObject.Properties['rawValue']
    if($null -eq $rawProperty -or $null -eq $rawProperty.Value){throw 'OnOff value lacks rawValue'}
    $raw = [string]$rawProperty.Value
    if ($raw -ceq '0x08') { return $false }
    if ($raw -ceq '0x09') { return $true }
    throw "OnOff rawValue is not a canonical Matter TLV Boolean: $raw"
}

function Get-MaindOnOffCommandIdForState {
    param([Parameter(Mandatory = $true)][bool]$State)
    if ($State) { return 1 }
    return 0
}
