Set-StrictMode -Version Latest

$script:MaindInventoryGlobalAttributes = @(65528,65529,65530,65531,65532,65533)
$script:MaindInventoryDescriptorBootstrap = @(0,1,2,3,4,65528,65529,65530,65531,65532,65533)

function New-MaindInventoryContext {
    param([UInt64]$NodeId)
    [pscustomobject]@{
        NodeId=$NodeId
        Endpoints=[Collections.Generic.HashSet[UInt64]]::new()
        ServerClusters=[Collections.Generic.HashSet[string]]::new()
        Attributes=[Collections.Generic.HashSet[string]]::new()
    }
}

function Add-MaindInventoryEndpoint { param($Context,[UInt64]$EndpointId) [void]$Context.Endpoints.Add($EndpointId) }
function Add-MaindInventoryServerCluster { param($Context,[UInt64]$EndpointId,[UInt64]$ClusterId) [void]$Context.ServerClusters.Add("$EndpointId/$ClusterId") }
function Add-MaindInventoryAttribute { param($Context,[UInt64]$EndpointId,[UInt64]$ClusterId,[UInt64]$AttributeId) [void]$Context.Attributes.Add("$EndpointId/$ClusterId/$AttributeId") }

function Get-MaindInventoryReadJson {
    param([UInt64]$NodeId,[UInt64]$EndpointId,[UInt64]$ClusterId,[UInt64]$AttributeId)
    ConvertTo-Json -Compress -InputObject ([ordered]@{nodeId=$NodeId;endpointId=$EndpointId;clusterId=$ClusterId;attributeId=$AttributeId})
}

function Test-MaindInventoryRequestAllowed {
    param($Context,[string]$Method,[string]$Path,[AllowNull()][AllowEmptyString()][string]$RequestBody)
    if($Method -ceq 'GET' -and $Path -ceq '/devices' -and [string]::IsNullOrEmpty($RequestBody)){return $true}
    if($Method -cne 'POST' -or $Path -cne '/interaction/readAttribute' -or [string]::IsNullOrWhiteSpace($RequestBody)){return $false}
    try{
        $body=ConvertFrom-Json $RequestBody -NoEnumerate -ErrorAction Stop
        $props=@($body.PSObject.Properties)
        if($props.Count-ne4-or(@($props.Name|Sort-Object)-join',')-cne'attributeId,clusterId,endpointId,nodeId'){return $false}
        $node=[UInt64]$body.nodeId;$ep=[UInt64]$body.endpointId;$cluster=[UInt64]$body.clusterId;$attr=[UInt64]$body.attributeId
        if($node-ne[UInt64]$Context.NodeId-or-not$Context.Endpoints.Contains($ep)){return $false}
        if($cluster-eq29-and$attr-in$script:MaindInventoryDescriptorBootstrap){return $true}
        if(-not$Context.ServerClusters.Contains("$ep/$cluster")){return $false}
        if($attr-in$script:MaindInventoryGlobalAttributes){return $true}
        return $Context.Attributes.Contains("$ep/$cluster/$attr")
    }catch{return $false}
}

function Assert-MaindInventoryRequestAllowed {
    param($Context,[string]$Method,[string]$Path,[AllowNull()][AllowEmptyString()][string]$RequestBody)
    if(-not(Test-MaindInventoryRequestAllowed @PSBoundParameters)){throw "Inventory request is not evidence-allowlisted: $Method $Path"}
}

function Get-MaindInventoryErrorClass {
    param([AllowNull()]$ErrorObject)
    $text=if($null-eq$ErrorObject){''}else{$ErrorObject|ConvertTo-Json -Compress -Depth 12}
    switch -Regex ($text){
        'UnsupportedAttribute|UNSUPPORTED_ATTRIBUTE' {'UNSUPPORTED_ATTRIBUTE';break}
        'UnsupportedCluster|UNSUPPORTED_CLUSTER' {'UNSUPPORTED_CLUSTER';break}
        'AccessDenied|ACCESS_DENIED|UnsupportedAccess' {'ACCESS_DENIED';break}
        'Timeout|TIMEOUT' {'TIMEOUT';break}
        default {'MATTER_ERROR'}
    }
}

function Get-MaindInventoryAttributeResult {
    param([string]$JsonText,[UInt64]$EndpointId,[UInt64]$ClusterId,[UInt64]$AttributeId)
    if([string]::IsNullOrWhiteSpace($JsonText)){throw 'Matter read response body is empty'}
    $parsed=ConvertFrom-Json $JsonText -Depth 50 -NoEnumerate -ErrorAction Stop
    if($parsed-isnot[Management.Automation.PSCustomObject]){throw 'Matter read response root must be an object'}
    $errorsProperty=$parsed.PSObject.Properties['errors']
    if($null-eq$errorsProperty-or$null-eq$errorsProperty.Value-or$errorsProperty.Value-isnot[Collections.IList]){throw 'Matter read response has no valid errors array'}
    $errors=@($errorsProperty.Value)
    if($errors.Count){return [pscustomobject]@{supported=$false;errors=$errors;error_class=(Get-MaindInventoryErrorClass $errors[0]);value=$null;parsed=$parsed}}
    $valuesProperty=$parsed.PSObject.Properties['values']
    if($null-eq$valuesProperty-or$null-eq$valuesProperty.Value-or$valuesProperty.Value-isnot[Collections.IList]){throw 'Matter read response has no valid values array'}
    $hits=@($valuesProperty.Value|Where-Object{
        $_-is[Management.Automation.PSCustomObject]-and$null-ne$_.PSObject.Properties['endpointId']-and
        $null-ne$_.PSObject.Properties['clusterId']-and$null-ne$_.PSObject.Properties['attributeId']-and
        [UInt64]$_.endpointId-eq$EndpointId-and[UInt64]$_.clusterId-eq$ClusterId-and[UInt64]$_.attributeId-eq$AttributeId
    })
    if($hits.Count-ne1){throw "Expected exactly one endpoint $EndpointId / cluster $ClusterId / attribute $AttributeId value"}
    $rawProperty=$hits[0].PSObject.Properties['rawValue']
    if($null-eq$rawProperty-or[string]$rawProperty.Value-notmatch'^0x(?:[0-9a-fA-F]{2})+$'){throw 'Matter attribute rawValue is absent or malformed'}
    $dataVersionProperty=$hits[0].PSObject.Properties['dataVersion']
    [pscustomobject]@{supported=$true;errors=@();error_class=$null;value=$hits[0];data_version=if($null-ne$dataVersionProperty){$dataVersionProperty.Value}else{$null};parsed=$parsed}
}

function Get-MaindInventoryUnsignedArray {
    param($Decoded)
    $elements=@($Decoded.elements)
    if($elements.Count-ne1-or$elements[0].type-notin@('array','list')){throw 'Expected one TLV array/list'}
    $result=[Collections.Generic.List[UInt64]]::new()
    foreach($child in @($elements[0].children)){
        if($child.type-notmatch'^unsigned_int_'-or$child.tag.control-cne'anonymous'){throw 'Expected anonymous unsigned list elements'}
        $result.Add([UInt64]$child.value)
    }
    @($result)
}

function Get-MaindInventoryDeviceTypes {
    param($Decoded)
    $elements=@($Decoded.elements);if($elements.Count-ne1-or$elements[0].type-notin@('array','list')){throw 'DeviceTypeList is not an array'}
    $out=[Collections.Generic.List[object]]::new()
    foreach($item in @($elements[0].children)){
        if($item.type-ne'structure'){throw 'DeviceTypeList item is not a structure'}
        $type=$null;$revision=$null
        foreach($field in @($item.children)){
            if($field.tag.control-ne'context'-or$field.type-notmatch'^unsigned_int_'){continue}
            if([int]$field.tag.number-eq0){$type=[UInt64]$field.value}
            if([int]$field.tag.number-eq1){$revision=[UInt64]$field.value}
        }
        $out.Add([pscustomobject]@{device_type=$type;revision=$revision})
    }
    @($out)
}

function Get-MaindInventoryKnownAttributes {
    param([UInt64]$ClusterId)
    $map=@{
        '3'=@(0); '6'=@(0,16384,16385,16386,16387); '8'=@(0,1,2,3,4,15,16,17,18,19,20,16384)
        '29'=@(0,1,2,3,4); '31'=@(0,1,2,3,4); '40'=@(0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22)
        '49'=@(0,1,2,3,4,5,6,7); '51'=@(0,1,2,3,4,5,6,7,8); '60'=@(0,1,2); '62'=@(0,1,2,3,4,5)
        '768'=@(0,1,2,3,4,5,6,7,8,15,16,17,18,22,23,25,26,27,32,33,34,36,37,38,16384,16385,16386,16387,16388,16389,16390,16394)
    }
    if($map.ContainsKey([string]$ClusterId)){return @($map[[string]$ClusterId])}
    @()
}

function ConvertTo-MaindInventoryPublic {
    param([object[]]$Attributes,[object[]]$Endpoints,[object[]]$Clusters)
    [ordered]@{
        generated_utc=[DateTime]::UtcNow.ToString('o')
        privacy='values, raw TLV, network identifiers, fabric metadata, serials and MAC addresses removed'
        endpoints=@($Endpoints)
        clusters=@($Clusters|ForEach-Object{[ordered]@{endpoint_id=$_.endpoint_id;cluster_id=$_.cluster_id;vendor_specific=$_.vendor_specific}})
        attributes=@($Attributes|ForEach-Object{[ordered]@{endpoint_id=$_.endpoint_id;cluster_id=$_.cluster_id;attribute_id=$_.attribute_id;status=$_.status;tlv_type=$_.tlv_type}})
    }
}

function ConvertFrom-MaindInventoryTlvNode {
    param($Node)
    $entry=[ordered]@{type=[string]$Node.type;tag=$Node.tag}
    if($Node.type-match'^(signed|unsigned)_int_|^boolean_|^float_|^utf8_'){$entry.value=$Node.value}
    elseif($Node.type-ceq'null'){$entry.value=$null}
    elseif($Node.type-match'^bytes_'){$entry.value_hex=[string]$Node.value_hex}
    elseif($Node.type-in@('array','list','structure')){$entry.children=@($Node.children|ForEach-Object{ConvertFrom-MaindInventoryTlvNode $_})}
    else{$entry.unsupported_representation=$true}
    [pscustomobject]$entry
}

function ConvertFrom-MaindInventoryTlvDocument {
    param($Decoded)
    @($Decoded.elements|ForEach-Object{ConvertFrom-MaindInventoryTlvNode $_})
}

function Get-MaindInventoryClusterName {
    param([UInt64]$ClusterId)
    $names=@{
        '3'='Identify';'4'='Groups';'6'='OnOff';'8'='LevelControl';'29'='Descriptor';'31'='AccessControl';'40'='BasicInformation'
        '42'='OTARequestor';'43'='OTALocalization';'44'='PowerSourceConfiguration';'45'='PowerSource';'46'='GeneralCommissioning'
        '48'='GeneralCommissioning';'49'='NetworkCommissioning';'51'='GeneralDiagnostics';'52'='SoftwareDiagnostics';'53'='ThreadNetworkDiagnostics'
        '54'='WiFiNetworkDiagnostics';'55'='EthernetNetworkDiagnostics';'56'='TimeSynchronization';'59'='Switch';'60'='AdministratorCommissioning'
        '62'='OperationalCredentials';'63'='GroupKeyManagement';'80'='ModeSelect';'768'='ColorControl';'321911814'='YandexVendor_0x132FFC06'
        '321911818'='YandexVendor_0x132FFC0A';'321911820'='YandexVendor_0x132FFC0C'
    }
    if($names.ContainsKey([string]$ClusterId)){$names[[string]$ClusterId]}else{"Cluster_$ClusterId"}
}

function Invoke-MaindFullInventory {
    param(
        $Context,$DevicesResult,[string]$ResultDirectory,[string]$Root,
        [Parameter(Mandatory=$true)][scriptblock]$ReadAttribute,
        [int]$MaxRequests=1000,[long]$MaxTotalBytes=67108864,[int]$RequestDelayMs=150,
        [int]$MaxSessionSeconds=600
    )
    $attributes=[Collections.Generic.List[object]]::new()
    $errors=[Collections.Generic.List[object]]::new()
    $endpointRows=[Collections.Generic.List[object]]::new()
    $clusterRows=[Collections.Generic.List[object]]::new()
    $commandRows=[Collections.Generic.List[object]]::new()
    $requested=[Collections.Generic.HashSet[string]]::new()
    $counters=[pscustomobject]@{request_count=0;total_bytes=[long]0}
    $sessionDeadline=[DateTime]::UtcNow.AddSeconds($MaxSessionSeconds)
    $jsonl=Join-Path $ResultDirectory 'attributes.jsonl'
    [IO.File]::WriteAllText($jsonl,'',[Text.UTF8Encoding]::new($false))

    function Add-InventoryError([string]$Class,[string]$Message,[UInt64]$Endpoint,[UInt64]$Cluster,[UInt64]$Attribute,[string]$Evidence){
        $errors.Add([pscustomobject][ordered]@{timestamp_utc=[DateTime]::UtcNow.ToString('o');class=$Class;message=$Message;endpoint_id=$Endpoint;cluster_id=$Cluster;attribute_id=$Attribute;evidence=$Evidence})
    }
    function Read-One([UInt64]$Endpoint,[UInt64]$Cluster,[UInt64]$Attribute,[string]$Purpose){
        $key="$Endpoint/$Cluster/$Attribute"
        if(-not$requested.Add($key)){return @($attributes|Where-Object{$_.endpoint_id-eq$Endpoint-and$_.cluster_id-eq$Cluster-and$_.attribute_id-eq$Attribute})[0]}
        if([DateTime]::UtcNow-ge$sessionDeadline){throw "Inventory session deadline exceeded: $MaxSessionSeconds seconds"}
        $counters.request_count++
        if($counters.request_count-gt$MaxRequests){throw "Inventory request limit exceeded: $MaxRequests"}
        if($RequestDelayMs-gt0){Start-Sleep -Milliseconds $RequestDelayMs}
        $evidence=('inventory_{0:D4}_ep{1}_cl{2}_at{3}'-f$counters.request_count,$Endpoint,$Cluster,$Attribute)
        try{
            $response=&$ReadAttribute $Endpoint $Cluster $Attribute $evidence
            $counters.total_bytes+=[Text.Encoding]::UTF8.GetByteCount([string]$response.Body)
            if($counters.total_bytes-gt$MaxTotalBytes){throw "Inventory total response limit exceeded: $MaxTotalBytes bytes"}
            $result=Get-MaindInventoryAttributeResult -JsonText $response.Body -EndpointId $Endpoint -ClusterId $Cluster -AttributeId $Attribute
            if(-not$result.supported){
                $record=[ordered]@{timestamp_utc=[DateTime]::UtcNow.ToString('o');endpoint_id=$Endpoint;cluster_id=$Cluster;cluster_name=Get-MaindInventoryClusterName $Cluster;attribute_id=$Attribute;purpose=$Purpose;status=$result.error_class;data_version=$null;raw_value=$null;tlv_type=$null;decoded=$null;matter_errors=@($result.errors);evidence=$evidence}
                Add-InventoryError $result.error_class 'Matter returned an attribute error' $Endpoint $Cluster $Attribute $evidence
            }else{
                $decoded=ConvertFrom-MaindMatterTlv -RawValue ([string]$result.value.rawValue) -Root $Root
                $plain=@(ConvertFrom-MaindInventoryTlvDocument $decoded)
                $record=[ordered]@{timestamp_utc=[DateTime]::UtcNow.ToString('o');endpoint_id=$Endpoint;cluster_id=$Cluster;cluster_name=Get-MaindInventoryClusterName $Cluster;attribute_id=$Attribute;purpose=$Purpose;status='SUCCESS';data_version=$result.data_version;raw_value=[string]$result.value.rawValue;tlv_type=if(@($decoded.elements).Count-eq1){[string]$decoded.elements[0].type}else{'multiple'};decoded=$plain;matter_errors=@();evidence=$evidence}
                $record['_decoded_document']=$decoded
            }
        }catch{
            $message=$_.Exception.Message
            # The HTTP helper deliberately keeps wget diagnostics in the
            # transport evidence rather than folding them into a generic
            # protocol exception. Include that evidence only for error
            # classification so a real wget timeout is not mislabeled as a
            # route/protocol failure.
            $diagnosticText=$message
            $transportPath=Join-Path $ResultDirectory ($evidence+'.transport.json')
            $stderrPath=Join-Path $ResultDirectory ($evidence+'.ssh_stderr.txt')
            if(Test-Path -LiteralPath $transportPath){$diagnosticText+=' '+(Get-Content -LiteralPath $transportPath -Raw -ErrorAction SilentlyContinue)}
            if(Test-Path -LiteralPath $stderrPath){$diagnosticText+=' '+(Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue)}
            $class=if($diagnosticText-match'(?i)timed?\s*out|timeout|deadline'){'TIMEOUT'}elseif($diagnosticText-match'ACCESS_DENIED'){'ACCESS_DENIED'}elseif($message-match'decode|TLV'){'DECODE_ERROR'}elseif($message-match'HTTP'){'HTTP_ERROR'}else{'MALFORMED_RESPONSE'}
            $record=[ordered]@{timestamp_utc=[DateTime]::UtcNow.ToString('o');endpoint_id=$Endpoint;cluster_id=$Cluster;cluster_name=Get-MaindInventoryClusterName $Cluster;attribute_id=$Attribute;purpose=$Purpose;status=$class;data_version=$null;raw_value=$null;tlv_type=$null;decoded=$null;matter_errors=@();evidence=$evidence}
            Add-InventoryError $class $message $Endpoint $Cluster $Attribute $evidence
        }
        $doc=$record['_decoded_document'];$record.Remove('_decoded_document')
        $object=[pscustomobject]$record;$attributes.Add($object)
        ($object|ConvertTo-Json -Compress -Depth 50)+[Environment]::NewLine|Add-Content -NoNewline -Encoding UTF8 $jsonl
        if($null-ne$doc){$object|Add-Member -NotePropertyName DecodedDocument -NotePropertyValue $doc}
        return $object
    }

    $queue=[Collections.Generic.Queue[UInt64]]::new()
    foreach($match in @($DevicesResult.Analysis.target_matches)){
        foreach($ep in @($match.endpoint_ids)){if($Context.Endpoints.Add([UInt64]$ep)){$queue.Enqueue([UInt64]$ep)}}
    }
    if($queue.Count-eq0){throw 'Target device advertises no endpoints'}
    $processed=[Collections.Generic.HashSet[UInt64]]::new()
    while($queue.Count){
        $ep=$queue.Dequeue();if(-not$processed.Add($ep)){continue}
        $descriptor=@{}
        foreach($attr in $script:MaindInventoryDescriptorBootstrap){$descriptor[[string]$attr]=Read-One $ep 29 $attr 'descriptor_bootstrap'}
        $server=@();$client=@();$parts=@();$types=@()
        try{if($descriptor['1'].status-eq'SUCCESS'){$server=@(Get-MaindInventoryUnsignedArray $descriptor['1'].DecodedDocument)}}catch{Add-InventoryError 'DECODE_ERROR' $_.Exception.Message $ep 29 1 $descriptor['1'].evidence}
        try{if($descriptor['2'].status-eq'SUCCESS'){$client=@(Get-MaindInventoryUnsignedArray $descriptor['2'].DecodedDocument)}}catch{Add-InventoryError 'DECODE_ERROR' $_.Exception.Message $ep 29 2 $descriptor['2'].evidence}
        try{if($descriptor['3'].status-eq'SUCCESS'){$parts=@(Get-MaindInventoryUnsignedArray $descriptor['3'].DecodedDocument)}}catch{Add-InventoryError 'DECODE_ERROR' $_.Exception.Message $ep 29 3 $descriptor['3'].evidence}
        try{if($descriptor['0'].status-eq'SUCCESS'){$types=@(Get-MaindInventoryDeviceTypes $descriptor['0'].DecodedDocument)}}catch{Add-InventoryError 'DECODE_ERROR' $_.Exception.Message $ep 29 0 $descriptor['0'].evidence}
        foreach($cluster in $server){Add-MaindInventoryServerCluster $Context $ep $cluster}
        foreach($part in $parts){if($Context.Endpoints.Add([UInt64]$part)){$queue.Enqueue([UInt64]$part)}}
        $endpointRows.Add([pscustomobject][ordered]@{endpoint_id=$ep;device_types=$types;server_clusters=$server;client_clusters=$client;parts=$parts})
    }

    foreach($epRow in @($endpointRows)){
        foreach($cluster in @($epRow.server_clusters)){
            $clusterRows.Add([pscustomobject][ordered]@{endpoint_id=$epRow.endpoint_id;cluster_id=[UInt64]$cluster;name=Get-MaindInventoryClusterName $cluster;vendor_specific=([UInt64]$cluster-ge65536)})
            $globals=@{}
            foreach($attr in $script:MaindInventoryGlobalAttributes){$globals[[string]$attr]=Read-One $epRow.endpoint_id $cluster $attr 'global_attribute'}
            $declared=@()
            try{if($globals['65531'].status-eq'SUCCESS'){$declared=@(Get-MaindInventoryUnsignedArray $globals['65531'].DecodedDocument)}}catch{Add-InventoryError 'DECODE_ERROR' $_.Exception.Message $epRow.endpoint_id $cluster 65531 $globals['65531'].evidence}
            if($declared.Count){
                $toRead=@($declared)
            }else{
                $toRead=@(Get-MaindInventoryKnownAttributes $cluster)
            }
            foreach($attr in $toRead){Add-MaindInventoryAttribute $Context $epRow.endpoint_id $cluster $attr}
            foreach($attr in $toRead){[void](Read-One $epRow.endpoint_id $cluster $attr 'declared_or_known_attribute')}
            foreach($kind in @(@{id=65528;name='generated'},@{id=65529;name='accepted'})){
                $item=$globals[[string]$kind.id];$values=@()
                try{if($item.status-eq'SUCCESS'){$values=@(Get-MaindInventoryUnsignedArray $item.DecodedDocument)}}catch{Add-InventoryError 'DECODE_ERROR' $_.Exception.Message $epRow.endpoint_id $cluster $kind.id $item.evidence}
                $commandRows.Add([pscustomobject][ordered]@{endpoint_id=$epRow.endpoint_id;cluster_id=[UInt64]$cluster;kind=$kind.name;command_ids=$values;source_attribute_id=$kind.id})
            }
        }
    }

    $attributes|ForEach-Object{if($_.PSObject.Properties['DecodedDocument']){$_.PSObject.Properties.Remove('DecodedDocument')}}
    ConvertTo-Json -InputObject @($endpointRows) -Depth 30|Set-Content -Encoding UTF8 (Join-Path $ResultDirectory 'endpoints.json')
    ConvertTo-Json -InputObject @($clusterRows) -Depth 10|Set-Content -Encoding UTF8 (Join-Path $ResultDirectory 'clusters.json')
    ConvertTo-Json -InputObject @($commandRows) -Depth 10|Set-Content -Encoding UTF8 (Join-Path $ResultDirectory 'commands.json')
    $vendorClusters=@($clusterRows|Where-Object vendor_specific|ForEach-Object{
        $c=$_;[ordered]@{endpoint_id=$c.endpoint_id;cluster_id=$c.cluster_id;cluster_hex=('0x{0:X8}'-f[UInt64]$c.cluster_id);name=$c.name;attributes=@($attributes|Where-Object {$_.endpoint_id-eq$c.endpoint_id-and$_.cluster_id-eq$c.cluster_id});commands=@($commandRows|Where-Object {$_.endpoint_id-eq$c.endpoint_id-and$_.cluster_id-eq$c.cluster_id})}
    })
    ConvertTo-Json -InputObject @($vendorClusters) -Depth 50|Set-Content -Encoding UTF8 (Join-Path $ResultDirectory 'vendor_clusters.json')
    $commissioning=[ordered]@{interpretation='Read-only evidence; free capacity is not proof that another controller can commission successfully';administrator_commissioning=@($attributes|Where-Object cluster_id -eq 60);operational_credentials=@($attributes|Where-Object cluster_id -eq 62);network_commissioning=@($attributes|Where-Object cluster_id -eq 49);access_control=@($attributes|Where-Object cluster_id -eq 31)}
    $commissioning|ConvertTo-Json -Depth 50|Set-Content -Encoding UTF8 (Join-Path $ResultDirectory 'commissioning.json')
    ConvertTo-Json -InputObject @($errors) -Depth 20|Set-Content -Encoding UTF8 (Join-Path $ResultDirectory 'errors.json')
    (ConvertTo-MaindInventoryPublic -Attributes @($attributes) -Endpoints @($endpointRows) -Clusters @($clusterRows))|ConvertTo-Json -Depth 30|Set-Content -Encoding UTF8 (Join-Path $ResultDirectory 'inventory.public.json')
    $clusterTable=@($clusterRows|Sort-Object endpoint_id,cluster_id|ForEach-Object{"| $($_.endpoint_id) | $($_.cluster_id) | ``0x$('{0:X8}'-f[UInt64]$_.cluster_id)`` | $($_.name) | $($_.vendor_specific) |"})-join[Environment]::NewLine
    $errorTable=if($errors.Count){@($errors|ForEach-Object{"| $($_.endpoint_id) | $($_.cluster_id) | $($_.attribute_id) | $($_.class) | $($_.evidence) |"})-join[Environment]::NewLine}else{'| — | — | — | none | — |'}
    $commissioningStatus=@($attributes|Where-Object cluster_id -in @(31,49,60,62)|Sort-Object endpoint_id,cluster_id,attribute_id|ForEach-Object{"| $($_.endpoint_id) | $($_.cluster_name) | $($_.attribute_id) | $($_.status) | $($_.tlv_type) |"})-join[Environment]::NewLine
    $vendorStatus=@($vendorClusters|ForEach-Object{"- $($_.cluster_hex) on endpoint $($_.endpoint_id): $(@($_.attributes|Where-Object status -eq 'SUCCESS').Count) readable attributes; command declarations only, never invoked."})-join[Environment]::NewLine
    $unsupportedCount=@($attributes|Where-Object status -eq 'UNSUPPORTED_ATTRIBUTE').Count
    $otherErrorCount=@($attributes|Where-Object {$_.status-ne'SUCCESS'-and$_.status-ne'UNSUPPORTED_ATTRIBUTE'}).Count
    $summary=@"
# Matter read-only inventory

Generated: $([DateTime]::UtcNow.ToString('o'))

## Scope and safety

Only GET /devices and POST /interaction/readAttribute were used. No invokeCommand or writeAttribute route is admitted by the inventory allowlist. Node ID: $($Context.NodeId). Requests: $($counters.request_count)/$MaxRequests. Response bytes: $($counters.total_bytes)/$MaxTotalBytes.

## Confirmed facts

- Endpoints discovered: $((@($endpointRows.endpoint_id)|Sort-Object)-join', ').
- Server clusters discovered: $($clusterRows.Count).
- Attribute reads recorded: $($attributes.Count); successful: $(@($attributes|Where-Object status -eq 'SUCCESS').Count); unsupported attributes: $unsupportedCount; HTTP/protocol/decode/access errors: $otherErrorCount.
- Vendor clusters: $((@($vendorClusters.cluster_hex)|Sort-Object)-join', '). Unknown vendor attributes are preserved as typed TLV without invented semantics.

## Endpoint/server cluster map

| Endpoint | Decimal cluster | Hex cluster | Name | Vendor-specific |
|---:|---:|---|---|---|
$clusterTable

## Commissioning-related read results

| Endpoint | Cluster | Attribute | Status | TLV type |
|---:|---|---:|---|---|
$commissioningStatus

Decoded values and raw evidence are retained in ``commissioning.json`` and ``attributes.jsonl``. These observations do not open a commissioning window and do not prove that a second fabric can be added.

## Yandex/vendor clusters

$vendorStatus

## Failed or unavailable reads

| Endpoint | Cluster | Attribute | Classification | Evidence |
|---:|---:|---:|---|---|
$errorTable

## Answers

1. Hardware/software information is available only to the extent exposed by Basic Information and other successfully readable attributes; see ``attributes.jsonl``.
2. Declared functions and modes are established from Descriptor ServerList, FeatureMap, AttributeList and command-list globals; command lists were not invoked.
3. Evidence relevant to a second controller is in ``commissioning.json``. SupportedFabrics/CommissionedFabrics and commissioning-window state are observations, not proof of successful independent pairing.
4. Network Commissioning data may show declared networks and interface state. Readability does not authorize or prove that Wi-Fi can be reconfigured without commissioning and access checks.
5. Yandex color-music evidence is limited to declared vendor clusters, readable attributes and command IDs in ``vendor_clusters.json``. Unknown fields remain unknown.
6. Unavailable information and reasons (unsupported, HTTP error, access denied, timeout, malformed response or TLV decode error) are listed separately in ``errors.json``.
7. Safe next experiments are further documented read-only interpretation of known standard attributes and offline correlation with maind symbols. No vendor command should be called until its schema and restoration behavior are proven.

## Interpretation boundary

This report separates declarations/readbacks from inference. Presence in AttributeList or AcceptedCommandList proves declaration only. It does not prove authorization, operational success, side-effect safety or independent-controller commissioning.
"@
    $summary|Set-Content -Encoding UTF8 (Join-Path $ResultDirectory 'summary.md')
    [pscustomobject]@{request_count=$counters.request_count;total_response_bytes=$counters.total_bytes;endpoints=@($endpointRows);clusters=@($clusterRows);attributes=@($attributes);errors=@($errors)}
}
