Set-StrictMode -Version Latest

function Get-MaindOnOffReadRequestJson {
    $target=Get-MaindHttpTarget
    $request = [ordered]@{
        nodeId = $target.NodeId
        endpointId = $target.EndpointId
        clusterId = 6
        attributeId = 0
    }
    return (ConvertTo-Json -InputObject $request -Compress)
}

function Test-MaindHttpRequestAllowed {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()][AllowEmptyString()][string]$RequestBody,
        [bool]$ReadOnOffAttributeEnabled = $false
    )

    # GET /devices is the mandatory preflight in both controller modes. Treat
    # an omitted body and PowerShell's empty-string coercion equivalently.
    if ($Method -ceq 'GET' -and $Path -ceq '/devices' -and
        [string]::IsNullOrEmpty($RequestBody)) {
        return $true
    }

    if (-not $ReadOnOffAttributeEnabled -or $Method -cne 'POST' -or
        $Path -cne '/interaction/readAttribute' -or
        [string]::IsNullOrEmpty($RequestBody)) {
        return $false
    }

    # The runtime test is intentionally narrower than the HTTP endpoint: only
    # the exact OnOff read is allowed. Extra fields or different attributes are
    # rejected before any network process is started.
    try {
        $target=Get-MaindHttpTarget
        $parsed = ConvertFrom-Json -InputObject $RequestBody -NoEnumerate -ErrorAction Stop
        $properties = @($parsed.PSObject.Properties)
        if ($properties.Count -ne 4) { return $false }
        $names = @($properties.Name | Sort-Object)
        if (($names -join ',') -cne 'attributeId,clusterId,endpointId,nodeId') { return $false }
        return (
            [UInt64]$parsed.nodeId -eq [UInt64]$target.NodeId -and
            [UInt64]$parsed.endpointId -eq [UInt64]$target.EndpointId -and
            [UInt64]$parsed.clusterId -eq 6 -and
            [UInt64]$parsed.attributeId -eq 0
        )
    } catch {
        return $false
    }
}

function Assert-MaindHttpRequestAllowed {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()][AllowEmptyString()][string]$RequestBody,
        [bool]$ReadOnOffAttributeEnabled = $false
    )
    if (-not (Test-MaindHttpRequestAllowed `
        -Method $Method `
        -Path $Path `
        -RequestBody $RequestBody `
        -ReadOnOffAttributeEnabled $ReadOnOffAttributeEnabled)) {
        throw "HTTP method/path is not allowlisted for this read-only test: $Method $Path"
    }
}

function Get-MaindHttpReadOnlyRequestPlan {
    param([bool]$ReadOnOffAttributeEnabled = $false)

    $plan = [System.Collections.Generic.List[object]]::new()
    $plan.Add([pscustomobject][ordered]@{
        method = 'GET'
        path = '/devices'
        body = $null
    })
    if ($ReadOnOffAttributeEnabled) {
        $plan.Add([pscustomobject][ordered]@{
            method = 'POST'
            path = '/interaction/readAttribute'
            body = Get-MaindOnOffReadRequestJson
        })
    }
    return @($plan)
}

function Get-MaindWgetHttpEvidence {
    param(
        # An SSH process may terminate with a non-zero exit code before it can
        # write diagnostics.  The empty string is therefore valid evidence and
        # must be classified from SshExitCode instead of failing parameter
        # binding under StrictMode.
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RawStderr,
        [Parameter(Mandatory = $true)][int]$SshExitCode,
        [Parameter(Mandatory = $true)][long]$BodyLength
    )

    $markerMatches = [regex]::Matches($RawStderr, '(?m)^__MAIND_WGET_EXIT__=([0-9]+)\s*$')
    $wgetExitCode = if ($markerMatches.Count -gt 0) {
        [int]$markerMatches[$markerMatches.Count - 1].Groups[1].Value
    } else {
        $null
    }
    $wgetStderr = [regex]::Replace(
        $RawStderr,
        '(?m)^__MAIND_WGET_EXIT__=[0-9]+\s*\r?\n?',
        ''
    )
    $statusMatches = [regex]::Matches(
        $wgetStderr,
        '(?m)^\s*HTTP/1\.[01]\s+([1-5][0-9]{2})\s*([^\r\n]*)'
    )
    $statusMatch = if ($statusMatches.Count -gt 0) {
        $statusMatches[$statusMatches.Count - 1]
    } else {
        $null
    }
    $statusCode = if ($null -ne $statusMatch) {
        [int]$statusMatch.Groups[1].Value
    } else {
        $null
    }
    $reason = if ($null -ne $statusMatch) {
        $statusMatch.Groups[2].Value.Trim()
    } else {
        $null
    }
    $headerLines = @(
        $wgetStderr -split '\r?\n' |
            Where-Object { $_ -match '^\s*[!#$%&''*+.^_`|~0-9A-Za-z-]+\s*:' } |
            ForEach-Object { $_.Trim() }
    )

    $transportError = $null
    $protocolError = $null
    $httpError = $null
    $transferError = $null
    $bodyError = $null

    if ($SshExitCode -ne 0) {
        $transportError = "SSH transport exited with code $SshExitCode"
    } elseif ($null -eq $wgetExitCode) {
        $transportError = 'Remote wget completion marker is missing'
    } elseif ($null -eq $statusCode) {
        $protocolError = 'No HTTP status line was received'
    } elseif ($statusCode -lt 200 -or $statusCode -ge 300) {
        $httpError = "HTTP route or handler returned $statusCode $reason".Trim()
    } elseif ($wgetExitCode -ne 0) {
        $transferError = "wget exited with code $wgetExitCode after HTTP $statusCode"
    }

    if ($BodyLength -eq 0) {
        $bodyError = 'HTTP response body is empty'
    }

    [pscustomobject][ordered]@{
        wget_exit_code = $wgetExitCode
        http_status = $statusCode
        reason = $reason
        headers = $headerLines
        wget_stderr = $wgetStderr
        transport_error = $transportError
        protocol_error = $protocolError
        http_error = $httpError
        transfer_error = $transferError
        body_error = $bodyError
    }
}

function Assert-MaindHttpResponse {
    param(
        [Parameter(Mandatory = $true)]$Evidence,
        [bool]$RequireNonEmptyBody = $true
    )

    if ($Evidence.transport_error) { throw "HTTP transport error: $($Evidence.transport_error)" }
    if ($Evidence.protocol_error) { throw "HTTP protocol error: $($Evidence.protocol_error)" }
    if ($Evidence.http_error) { throw "HTTP route/handler error: $($Evidence.http_error)" }
    if ($Evidence.transfer_error) { throw "HTTP transfer error: $($Evidence.transfer_error)" }
    if ($RequireNonEmptyBody -and $Evidence.body_error) {
        throw "HTTP body error: $($Evidence.body_error)"
    }
}

function ConvertFrom-MaindRawHttpResponse {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RawResponse,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RawStderr,
        [Parameter(Mandatory = $true)][int]$SshExitCode,
        [ValidateSet('telnet','native')][string]$TransportKind = 'telnet'
    )

    $markerName = if($TransportKind-ceq'native'){'__MAIND_NATIVE_EXIT__'}else{'__MAIND_TELNET_EXIT__'}
    $markerPattern = '(?m)^'+[regex]::Escape($markerName)+'=([0-9]+)\s*$'
    $markerMatches = [regex]::Matches($RawStderr, $markerPattern)
    $transportExitCode = if ($markerMatches.Count) {
        [int]$markerMatches[$markerMatches.Count - 1].Groups[1].Value
    } else { $null }
    $diagnosticStderr = [regex]::Replace(
        $RawStderr,
        '(?m)^'+[regex]::Escape($markerName)+'=[0-9]+\s*\r?\n?',
        ''
    )

    $separator = "`r`n`r`n"
    $separatorIndex = $RawResponse.IndexOf($separator, [StringComparison]::Ordinal)
    $headerText = if ($separatorIndex -ge 0) { $RawResponse.Substring(0, $separatorIndex) } else { '' }
    $body = if ($separatorIndex -ge 0) { $RawResponse.Substring($separatorIndex + $separator.Length) } else { '' }
    $lines = @()
    if ($headerText) { $lines = @($headerText -split "`r`n") }
    $statusMatch = if ($lines.Count) {
        [regex]::Match($lines[0], '^HTTP/1\.[01]\s+([1-5][0-9]{2})(?:\s+(.*))?$')
    } else { $null }
    $statusCode = if ($null -ne $statusMatch -and $statusMatch.Success) {
        [int]$statusMatch.Groups[1].Value
    } else { $null }
    $reason = if ($null -ne $statusMatch -and $statusMatch.Success) {
        $statusMatch.Groups[2].Value.Trim()
    } else { $null }
    $headers = @($lines | Select-Object -Skip 1)
    $contentLengthLines = @($headers | Where-Object { $_ -match '(?i)^Content-Length\s*:' })
    $contentLength = $null
    if ($contentLengthLines.Count -eq 1 -and $contentLengthLines[0] -match '(?i)^Content-Length\s*:\s*([0-9]+)\s*$') {
        $contentLength = [long]$matches[1]
    }
    $actualBodyLength = [Text.Encoding]::UTF8.GetByteCount($body)

    $transportError = $null
    $protocolError = $null
    $httpError = $null
    $transferError = $null
    $bodyError = $null
    if ($SshExitCode -ne 0) {
        $transportError = "SSH transport exited with code $SshExitCode"
    } elseif ($null -eq $transportExitCode) {
        $transportError = 'Remote raw-HTTP completion marker is missing'
    } elseif ($transportExitCode -ne 0) {
        $transferError = if($TransportKind-ceq'native'){
            "maind-http-local exited with code $transportExitCode"
        }else{
            "BusyBox telnet exited with code $transportExitCode"
        }
    } elseif ($separatorIndex -lt 0 -or $null -eq $statusCode) {
        $protocolError = 'A complete HTTP/1.x status and CRLF header block was not received'
    } elseif (@($headers | Where-Object { $_ -match '(?i)^Transfer-Encoding\s*:' }).Count) {
        $protocolError = 'Transfer-Encoding responses are not accepted by the bounded raw HTTP transport'
    } elseif ($contentLengthLines.Count -ne 1 -or $null -eq $contentLength) {
        $protocolError = 'Exactly one valid Content-Length response header is required'
    } elseif ($actualBodyLength -ne $contentLength) {
        $protocolError = "HTTP body length mismatch: header=$contentLength actual=$actualBodyLength"
    } elseif ($statusCode -lt 200 -or $statusCode -ge 300) {
        $httpError = "HTTP route or handler returned $statusCode $reason".Trim()
    }
    if ($actualBodyLength -eq 0) { $bodyError = 'HTTP response body is empty' }

    [pscustomobject][ordered]@{
        transport = if($TransportKind-ceq'native'){'maind_http_local_native_http_1_1'}else{'busybox_telnet_raw_http_1_1'}
        transport_exit_code = $transportExitCode
        http_status = $statusCode
        reason = $reason
        headers = $headers
        diagnostic_stderr = $diagnosticStderr
        content_length = $contentLength
        body_length = $actualBodyLength
        body = $body
        transport_error = $transportError
        protocol_error = $protocolError
        http_error = $httpError
        transfer_error = $transferError
        body_error = $bodyError
    }
}

function New-MaindRawHttpPostRequest {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Body
    )
    if($Path-notmatch'^/[A-Za-z0-9/_-]+$'){throw 'Raw HTTP path contains forbidden characters.'}
    $length=[Text.UTF8Encoding]::new($false).GetByteCount($Body)
    return "POST $Path HTTP/1.1`r`nHost: 127.0.0.1:8765`r`nContent-Type: application/json`r`nContent-Length: $length`r`nConnection: close`r`n`r`n$Body"
}

function ConvertTo-MatterNodeIdValue {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $null }
    $text = ([string]$Value).Trim()
    if ($text -match '^0[xX]([0-9a-fA-F]+)$') {
        try { return [Convert]::ToUInt64($matches[1], 16) } catch { return $null }
    }
    $parsed = [UInt64]0
    if ([UInt64]::TryParse($text, [ref]$parsed)) { return $parsed }
    return $null
}

function Get-MaindJsonKind {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string] -or $Value.GetType().IsPrimitive) { return 'scalar' }
    if ($Value -is [System.Collections.IDictionary] -or
        $Value -is [System.Management.Automation.PSCustomObject]) { return 'object' }
    if ($Value -is [System.Collections.IEnumerable]) { return 'array' }
    return 'object'
}

function Get-MaindDevicesJsonAnalysis {
    param(
        [Parameter(Mandatory = $true)][string]$JsonText,
        [Nullable[UInt64]]$TargetNodeId = $null,
        [Nullable[UInt16]]$TargetEndpointId = $null
    )

    $target=Get-MaindHttpTarget
    if($null -eq $TargetNodeId){$TargetNodeId=[UInt64]$target.NodeId}
    if($null -eq $TargetEndpointId){$TargetEndpointId=[UInt16]$target.EndpointId}

    $parsed = ConvertFrom-Json -InputObject $JsonText -Depth 30 -NoEnumerate -ErrorAction Stop
    $hits = [System.Collections.Generic.List[object]]::new()

    function Visit-MaindJsonValue {
        param([AllowNull()]$Value, [string]$Path, [int]$Depth)
        if ($null -eq $Value -or $Depth -gt 64) { return }

        if ($Value -is [System.Collections.IDictionary]) {
            if ($Value.Contains('nodeId')) {
                $raw = $Value['nodeId']
                $numeric = ConvertTo-MatterNodeIdValue $raw
                $endpointIds = if ($Value.Contains('endpoints') -and $null -ne $Value['endpoints']) {
                    @($Value['endpoints'] | ForEach-Object { ConvertTo-MatterNodeIdValue $_ } | Where-Object { $null -ne $_ })
                } else { @() }
                $hits.Add([pscustomobject]@{
                    path = $Path
                    raw_node_id = [string]$raw
                    numeric_node_id = $numeric
                    endpoint_ids = @($endpointIds)
                })
            }
            foreach ($key in $Value.Keys) {
                Visit-MaindJsonValue $Value[$key] "$Path.$key" ($Depth + 1)
            }
            return
        }

        if ($Value -is [System.Management.Automation.PSCustomObject]) {
            $properties = @($Value.PSObject.Properties)
            $nodeProperty = $properties | Where-Object { $_.Name -ceq 'nodeId' } | Select-Object -First 1
            if ($null -ne $nodeProperty) {
                $numeric = ConvertTo-MatterNodeIdValue $nodeProperty.Value
                $endpointsProperty = $properties | Where-Object { $_.Name -ceq 'endpoints' } | Select-Object -First 1
                $endpointIds = if ($null -ne $endpointsProperty -and $null -ne $endpointsProperty.Value) {
                    @($endpointsProperty.Value | ForEach-Object { ConvertTo-MatterNodeIdValue $_ } | Where-Object { $null -ne $_ })
                } else { @() }
                $hits.Add([pscustomobject]@{
                    path = $Path
                    raw_node_id = [string]$nodeProperty.Value
                    numeric_node_id = $numeric
                    endpoint_ids = @($endpointIds)
                })
            }
            foreach ($property in $properties) {
                Visit-MaindJsonValue $property.Value "$Path.$($property.Name)" ($Depth + 1)
            }
            return
        }

        if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
            $index = 0
            foreach ($item in $Value) {
                Visit-MaindJsonValue $item "$Path[$index]" ($Depth + 1)
                $index++
            }
        }
    }

    Visit-MaindJsonValue $parsed '$' 0
    $rootProperties = if ((Get-MaindJsonKind $parsed) -eq 'object') {
        @($parsed.PSObject.Properties.Name)
    } else {
        @()
    }
    $targetMatches = @($hits | Where-Object {
        $null -ne $_.numeric_node_id -and [UInt64]$_.numeric_node_id -eq $TargetNodeId
    })

    [pscustomobject]@{
        Parsed = $parsed
        Analysis = [pscustomobject][ordered]@{
            parse_success = $true
            root_kind = Get-MaindJsonKind $parsed
            root_properties = $rootProperties
            node_id_object_count = $hits.Count
            node_id_objects = @($hits)
            target_node_id = $TargetNodeId
            target_matches = $targetMatches
            target_found = ($targetMatches.Count -gt 0)
            target_endpoint_id = $TargetEndpointId
            target_endpoint_found = (@($targetMatches | Where-Object { $TargetEndpointId -in @($_.endpoint_ids) }).Count -gt 0)
        }
    }
}

function Get-MaindJsonPathInventory {
    param([AllowNull()]$Parsed)

    $items = [System.Collections.Generic.List[object]]::new()
    function Visit-MaindInventoryValue {
        param([AllowNull()]$Value, [string]$Path, [int]$Depth)
        if ($Depth -gt 64) {
            $items.Add([pscustomobject]@{path=$Path; kind='depth_limit'; value=$null})
            return
        }
        if ($null -eq $Value) {
            $items.Add([pscustomobject]@{path=$Path; kind='null'; value=$null})
            return
        }
        if ($Value -is [System.Collections.IDictionary]) {
            foreach ($key in $Value.Keys) {
                Visit-MaindInventoryValue $Value[$key] "$Path.$key" ($Depth + 1)
            }
            return
        }
        if ($Value -is [System.Management.Automation.PSCustomObject]) {
            foreach ($property in $Value.PSObject.Properties) {
                Visit-MaindInventoryValue $property.Value "$Path.$($property.Name)" ($Depth + 1)
            }
            return
        }
        if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
            $index = 0
            foreach ($entry in $Value) {
                Visit-MaindInventoryValue $entry "$Path[$index]" ($Depth + 1)
                $index++
            }
            return
        }
        $kind = if ($Value -is [bool]) {
            'boolean'
        } elseif ($Value -is [string]) {
            'string'
        } elseif ($Value -is [ValueType]) {
            'number_or_value_type'
        } else {
            $Value.GetType().FullName
        }
        $items.Add([pscustomobject]@{path=$Path; kind=$kind; value=$Value})
    }

    Visit-MaindInventoryValue $Parsed '$' 0
    return @($items)
}
