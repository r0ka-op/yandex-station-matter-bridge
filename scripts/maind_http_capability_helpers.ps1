Set-StrictMode -Version Latest

function Get-MaindCapabilityReadRequestJson {
    param(
        [Parameter(Mandatory = $true)][UInt64]$ClusterId,
        [Parameter(Mandatory = $true)][UInt64]$AttributeId
    )
    $target=Get-MaindHttpTarget
    return (ConvertTo-Json -Compress -InputObject ([ordered]@{
        nodeId = $target.NodeId
        endpointId = $target.EndpointId
        clusterId = $ClusterId
        attributeId = $AttributeId
    }))
}

function Test-MaindCapabilityReadPairAllowed {
    param([UInt64]$ClusterId,[UInt64]$AttributeId)
    $key = "$ClusterId/$AttributeId"
    return $key -in @(
        '29/1',
        '8/0','8/65532','8/65529',
        '768/16394','768/8','768/65532','768/65529',
        '768/0','768/1','768/3','768/4','768/7',
        '321911814/65529','321911814/65531','321911814/65532'
    )
}

function Test-MaindCapabilityRequestAllowed {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()][AllowEmptyString()][string]$RequestBody
    )
    if ($Method -ceq 'GET' -and $Path -ceq '/devices' -and
        [string]::IsNullOrEmpty($RequestBody)) { return $true }
    if ($Method -cne 'POST' -or $Path -cne '/interaction/readAttribute' -or
        [string]::IsNullOrEmpty($RequestBody)) { return $false }
    try {
        $target=Get-MaindHttpTarget
        $body = ConvertFrom-Json -InputObject $RequestBody -NoEnumerate -ErrorAction Stop
        $properties = @($body.PSObject.Properties)
        if ($properties.Count -ne 4 -or
            (@($properties.Name | Sort-Object) -join ',') -cne
            'attributeId,clusterId,endpointId,nodeId') { return $false }
        if ([UInt64]$body.nodeId -ne [UInt64]$target.NodeId -or
            [UInt64]$body.endpointId -ne [UInt64]$target.EndpointId) { return $false }
        return Test-MaindCapabilityReadPairAllowed `
            -ClusterId ([UInt64]$body.clusterId) `
            -AttributeId ([UInt64]$body.attributeId)
    } catch { return $false }
}

function Assert-MaindCapabilityRequestAllowed {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()][AllowEmptyString()][string]$RequestBody
    )
    if (-not (Test-MaindCapabilityRequestAllowed -Method $Method -Path $Path `
        -RequestBody $RequestBody)) {
        throw "HTTP request is not allowlisted for capability discovery: $Method $Path"
    }
}

function Get-MaindAttributeResult {
    param(
        [Parameter(Mandatory = $true)][string]$JsonText,
        [Parameter(Mandatory = $true)][UInt64]$ClusterId,
        [Parameter(Mandatory = $true)][UInt64]$AttributeId,
        [UInt64]$EndpointId = 1
    )
    if ([string]::IsNullOrWhiteSpace($JsonText)) { throw 'Matter read response body is empty' }
    $parsed = ConvertFrom-Json -InputObject $JsonText -Depth 30 -NoEnumerate -ErrorAction Stop
    if ($parsed -isnot [Management.Automation.PSCustomObject] -and
        $parsed -isnot [Collections.IDictionary]) {
        throw 'Matter read response root must be an object'
    }
    $errorsProperty = $parsed.PSObject.Properties['errors']
    if ($null -eq $errorsProperty) { throw 'Matter read response lacks errors property' }
    if ($null -eq $errorsProperty.Value) { throw 'Matter read errors property is null' }
    if ($errorsProperty.Value -isnot [Collections.IList]) {
        throw 'Matter read errors property must be an array'
    }
    $errors = @($errorsProperty.Value)
    if ($errors.Count -gt 0) {
        return [pscustomobject]@{
            supported = $false; errors = $errors; value = $null; parsed = $parsed
        }
    }
    $valuesProperty = $parsed.PSObject.Properties['values']
    if ($null -eq $valuesProperty -or $null -eq $valuesProperty.Value) {
        throw 'Matter read response lacks values array'
    }
    if ($valuesProperty.Value -isnot [Collections.IList]) {
        throw 'Matter read values property must be an array'
    }
    $values = @($valuesProperty.Value)
    # Do not call this variable $matches: PowerShell's case-insensitive
    # automatic $Matches variable is overwritten by the -notmatch below.
    $valueMatches = @($values | Where-Object {
        if ($_ -isnot [Management.Automation.PSCustomObject]) { return $false }
        foreach ($required in @('endpointId','clusterId','attributeId')) {
            if ($null -eq $_.PSObject.Properties[$required]) { return $false }
        }
        [UInt64]$_.endpointId -eq $EndpointId -and [UInt64]$_.clusterId -eq $ClusterId -and
        [UInt64]$_.attributeId -eq $AttributeId
    })
    if ($valueMatches.Count -ne 1) {
        throw "Expected exactly one endpoint $EndpointId / cluster $ClusterId / attribute $AttributeId value"
    }
    $rawProperty = $valueMatches[0].PSObject.Properties['rawValue']
    if ($null -eq $rawProperty -or $null -eq $rawProperty.Value) {
        throw 'Matter attribute value lacks rawValue'
    }
    $raw = [string]$rawProperty.Value
    if ($raw -notmatch '^0x(?:[0-9a-fA-F]{2})+$') {
        throw "Attribute rawValue is not valid byte-aligned hex: $raw"
    }
    return [pscustomobject]@{
        supported = $true; errors = @(); value = $valueMatches[0]; parsed = $parsed
    }
}

function ConvertFrom-MaindMatterTlv {
    param(
        [Parameter(Mandatory = $true)][string]$RawValue,
        [Parameter(Mandatory = $true)][string]$Root
    )
    $python = (Get-Command python -ErrorAction Stop).Source
    $decoder = Join-Path $Root 'scripts\decode_matter_tlv.py'
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $python
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($arg in @($decoder,'--hex',$RawValue)) { [void]$psi.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $psi
    if (-not $process.Start()) { throw 'Matter TLV decoder failed to start' }
    try {
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "Matter TLV decode failed: $stderr" }
        return ConvertFrom-Json -InputObject $stdout -Depth 50 -NoEnumerate -ErrorAction Stop
    } finally { $process.Dispose() }
}

function Get-MaindUnsignedListFromTlv {
    param([Parameter(Mandatory = $true)]$Decoded)
    $elements = @($Decoded.elements)
    if ($elements.Count -ne 1 -or $elements[0].type -notin @('array','list')) {
        throw 'TLV must contain exactly one array/list container'
    }
    $values = [Collections.Generic.List[UInt64]]::new()
    foreach ($child in @($elements[0].children)) {
        if ($child.type -notmatch '^unsigned_int_' -or $child.tag.control -cne 'anonymous') {
            throw 'TLV list contains a non-anonymous or non-unsigned element'
        }
        $values.Add([UInt64]$child.value)
    }
    if (@($values | Select-Object -Unique).Count -ne $values.Count) {
        throw 'TLV list contains duplicate integer values'
    }
    return @($values)
}

function Get-MaindServerListFromTlv {
    param([Parameter(Mandatory = $true)]$Decoded)
    return @(Get-MaindUnsignedListFromTlv $Decoded)
}

function Get-MaindUnsignedScalarFromTlv {
    param([Parameter(Mandatory = $true)]$Decoded)
    $elements = @($Decoded.elements)
    if ($elements.Count -ne 1 -or $elements[0].type -notmatch '^unsigned_int_' -or
        $elements[0].tag.control -cne 'anonymous') {
        throw 'Expected exactly one anonymous unsigned TLV scalar'
    }
    return [UInt64]$elements[0].value
}

function Get-MaindBooleanScalarFromTlv {
    param([Parameter(Mandatory = $true)]$Decoded)
    $elements = @($Decoded.elements)
    if ($elements.Count -ne 1 -or
        $elements[0].type -notin @('boolean_false','boolean_true') -or
        $elements[0].tag.control -cne 'anonymous') {
        throw 'Expected exactly one anonymous Boolean TLV scalar'
    }
    return [bool]$elements[0].value
}

function Get-MaindNullableUnsignedScalarFromTlv {
    param([Parameter(Mandatory = $true)]$Decoded)
    $elements = @($Decoded.elements)
    if ($elements.Count -ne 1 -or $elements[0].tag.control -cne 'anonymous') {
        throw 'Expected exactly one anonymous nullable unsigned TLV scalar'
    }
    if ($elements[0].type -ceq 'null') {
        return [pscustomobject]@{ isNull = $true; value = $null; tlvType = 'null' }
    }
    if ($elements[0].type -notmatch '^unsigned_int_') {
        throw 'Expected an anonymous unsigned integer or Null TLV scalar'
    }
    return [pscustomobject]@{
        isNull = $false
        value = [UInt64]$elements[0].value
        tlvType = [string]$elements[0].type
    }
}
