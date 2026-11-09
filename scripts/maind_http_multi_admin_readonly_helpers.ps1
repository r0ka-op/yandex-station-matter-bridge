Set-StrictMode -Version Latest

function Get-MaindMultiAdminReadPlan {
    param([Parameter(Mandatory=$true)][UInt64]$NodeId)
    return @(
        [pscustomobject]@{nodeId=$NodeId;endpointId=0;clusterId=60;attributeId=65529;name='administrator_commissioning_accepted_command_list';kind='list'},
        [pscustomobject]@{nodeId=$NodeId;endpointId=0;clusterId=60;attributeId=65528;name='administrator_commissioning_generated_command_list';kind='list'},
        [pscustomobject]@{nodeId=$NodeId;endpointId=0;clusterId=60;attributeId=65531;name='administrator_commissioning_attribute_list';kind='list'},
        [pscustomobject]@{nodeId=$NodeId;endpointId=0;clusterId=60;attributeId=65532;name='administrator_commissioning_feature_map';kind='scalar'},
        [pscustomobject]@{nodeId=$NodeId;endpointId=0;clusterId=60;attributeId=65533;name='administrator_commissioning_cluster_revision';kind='scalar'},
        [pscustomobject]@{nodeId=$NodeId;endpointId=0;clusterId=60;attributeId=0;name='administrator_commissioning_window_status';kind='scalar'},
        [pscustomobject]@{nodeId=$NodeId;endpointId=0;clusterId=60;attributeId=1;name='administrator_commissioning_admin_fabric_index';kind='nullable'},
        [pscustomobject]@{nodeId=$NodeId;endpointId=0;clusterId=60;attributeId=2;name='administrator_commissioning_admin_vendor_id';kind='nullable'},
        [pscustomobject]@{nodeId=$NodeId;endpointId=0;clusterId=62;attributeId=2;name='operational_credentials_supported_fabrics';kind='scalar'},
        [pscustomobject]@{nodeId=$NodeId;endpointId=0;clusterId=62;attributeId=3;name='operational_credentials_commissioned_fabrics';kind='scalar'},
        [pscustomobject]@{nodeId=$NodeId;endpointId=0;clusterId=62;attributeId=5;name='operational_credentials_current_fabric_index';kind='scalar'}
    )
}

function Get-MaindMultiAdminReadRequestJson {
    param(
        [Parameter(Mandatory=$true)][UInt64]$NodeId,
        [Parameter(Mandatory=$true)][UInt64]$ClusterId,
        [Parameter(Mandatory=$true)][UInt64]$AttributeId
    )
    ConvertTo-Json -Compress -InputObject ([ordered]@{
        nodeId=$NodeId; endpointId=0; clusterId=$ClusterId; attributeId=$AttributeId
    })
}

function Test-MaindMultiAdminReadPairAllowed {
    param([UInt64]$ClusterId,[UInt64]$AttributeId)
    return "$ClusterId/$AttributeId" -in @(
        '60/65529','60/65528','60/65531','60/65532','60/65533','60/0','60/1','60/2',
        '62/2','62/3','62/5'
    )
}

function Test-MaindMultiAdminRequestAllowed {
    param(
        [Parameter(Mandatory=$true)][string]$Method,
        [Parameter(Mandatory=$true)][string]$Path,
        [AllowNull()][AllowEmptyString()][string]$RequestBody,
        [Parameter(Mandatory=$true)][UInt64]$ExpectedNodeId
    )
    if($Method -ceq 'GET' -and $Path -ceq '/devices' -and
        [string]::IsNullOrEmpty($RequestBody)){ return $true }
    if($Method -cne 'POST' -or $Path -cne '/interaction/readAttribute' -or
        [string]::IsNullOrEmpty($RequestBody)){ return $false }
    try {
        $body=ConvertFrom-Json -InputObject $RequestBody -NoEnumerate -ErrorAction Stop
        $properties=@($body.PSObject.Properties)
        if($properties.Count -ne 4 -or
            (@($properties.Name|Sort-Object)-join ',') -cne 'attributeId,clusterId,endpointId,nodeId'){
            return $false
        }
        if([UInt64]$body.nodeId -ne $ExpectedNodeId -or [UInt64]$body.endpointId -ne 0){
            return $false
        }
        return Test-MaindMultiAdminReadPairAllowed -ClusterId ([UInt64]$body.clusterId) `
            -AttributeId ([UInt64]$body.attributeId)
    } catch { return $false }
}

function Assert-MaindMultiAdminRequestAllowed {
    param(
        [Parameter(Mandatory=$true)][string]$Method,
        [Parameter(Mandatory=$true)][string]$Path,
        [AllowNull()][AllowEmptyString()][string]$RequestBody,
        [Parameter(Mandatory=$true)][UInt64]$ExpectedNodeId
    )
    if(-not(Test-MaindMultiAdminRequestAllowed -Method $Method -Path $Path `
        -RequestBody $RequestBody -ExpectedNodeId $ExpectedNodeId)){
        throw "HTTP request is not allowlisted for MultiAdminReadOnly: $Method $Path"
    }
}
