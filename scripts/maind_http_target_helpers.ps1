Set-StrictMode -Version Latest

$script:MaindHttpTarget = $null

function Set-MaindHttpTarget {
    param(
        [Parameter(Mandatory=$true)][ValidateRange(1,[UInt64]::MaxValue)][UInt64]$NodeId,
        [Parameter(Mandatory=$true)][ValidateRange(0,65535)][UInt16]$EndpointId
    )
    $script:MaindHttpTarget = [pscustomobject][ordered]@{
        NodeId = $NodeId
        EndpointId = $EndpointId
    }
}

function Get-MaindHttpTarget {
    if ($null -eq $script:MaindHttpTarget) {
        throw 'Matter target is not configured. Call Set-MaindHttpTarget first.'
    }
    return $script:MaindHttpTarget
}
