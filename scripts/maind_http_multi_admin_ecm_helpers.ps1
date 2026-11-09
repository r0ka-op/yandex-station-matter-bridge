Set-StrictMode -Version Latest

function Get-MatterWsEnvelopeKind {
    param(
        [Parameter(Mandatory=$true)]$Message,
        [Parameter(Mandatory=$true)][string]$ExpectedMessageId
    )
    $messageIdProperty=$Message.PSObject.Properties['message_id']
    if($null-eq$messageIdProperty){return 'unsolicited'}
    $actual=[string]$messageIdProperty.Value
    if([string]::IsNullOrWhiteSpace($actual)){return 'unsolicited'}
    if($actual-cne$ExpectedMessageId){return 'foreign_response'}
    return 'matched_response'
}

function Get-MatterWsProperty {
    param(
        [Parameter(Mandatory=$true)]$Message,
        [Parameter(Mandatory=$true)][string]$Name
    )
    return $Message.PSObject.Properties[$Name]
}

function New-MaindEcmTimingContext {
    param([Parameter(Mandatory=$true)][ValidateRange(1500,1800)][int]$WatchdogSeconds)
    # All values are relative to a monotonic Stopwatch started before staging.
    # With the production 1500-second watchdog, the main path stops at 1140,
    # rollback/verify-clean owns the next 240 seconds, and the independent
    # station watchdog retains a final 120-second safety margin.
    $watchdogSafetySeconds=120
    $rollbackBudgetSeconds=240
    $mainDeadlineSeconds=$WatchdogSeconds-$watchdogSafetySeconds-$rollbackBudgetSeconds
    if($mainDeadlineSeconds-lt540){throw 'ECM watchdog is too short for bounded main, rollback, and safety budgets.'}
    [pscustomobject]@{
        Stopwatch=[Diagnostics.Stopwatch]::StartNew()
        WatchdogSeconds=$WatchdogSeconds
        PreparationDeadlineSeconds=[Math]::Min(240,$mainDeadlineSeconds-300)
        PostDeadlineSeconds=[Math]::Min(360,$mainDeadlineSeconds-240)
        CommissioningDeadlineSeconds=[Math]::Min(840,$mainDeadlineSeconds-120)
        ReadbackDeadlineSeconds=[Math]::Min(1020,$mainDeadlineSeconds-60)
        MainDeadlineSeconds=$mainDeadlineSeconds
        RollbackDeadlineSeconds=$WatchdogSeconds-$watchdogSafetySeconds
        RollbackBudgetSeconds=$rollbackBudgetSeconds
        WatchdogSafetySeconds=$watchdogSafetySeconds
    }
}

function Get-MaindEcmDeadlineSeconds {
    param([Parameter(Mandatory=$true)]$Timing,[Parameter(Mandatory=$true)]
        [ValidateSet('Preparation','Post','Commissioning','Readback','Main','Rollback')][string]$Phase)
    switch($Phase){
        Preparation { $Timing.PreparationDeadlineSeconds }
        Post { $Timing.PostDeadlineSeconds }
        Commissioning { $Timing.CommissioningDeadlineSeconds }
        Readback { $Timing.ReadbackDeadlineSeconds }
        Main { $Timing.MainDeadlineSeconds }
        Rollback { $Timing.RollbackDeadlineSeconds }
    }
}

function Get-MaindEcmBoundedTimeoutMilliseconds {
    param(
        [Parameter(Mandatory=$true)]$Timing,
        [Parameter(Mandatory=$true)][ValidateRange(1,1800)][int]$LocalTimeoutSeconds,
        [Parameter(Mandatory=$true)][ValidateSet('Preparation','Post','Commissioning','Readback','Main','Rollback')][string]$Phase,
        [ValidateRange(0,1800)][int]$MinimumRemainingSeconds=1
    )
    $deadline=Get-MaindEcmDeadlineSeconds $Timing $Phase
    $remaining=$deadline-$Timing.Stopwatch.Elapsed.TotalSeconds
    if($remaining-lt$MinimumRemainingSeconds){
        throw "ECM $Phase budget exhausted before operation start; rollback must begin."
    }
    [int][Math]::Max(1,[Math]::Floor([Math]::Min($LocalTimeoutSeconds,$remaining)*1000))
}

function Get-MaindEcmTimingSummary {
    param([Parameter(Mandatory=$true)]$Timing)
    [ordered]@{
        watchdog_seconds=$Timing.WatchdogSeconds
        preparation_deadline_seconds=$Timing.PreparationDeadlineSeconds
        post_deadline_seconds=$Timing.PostDeadlineSeconds
        commissioning_deadline_seconds=$Timing.CommissioningDeadlineSeconds
        readback_deadline_seconds=$Timing.ReadbackDeadlineSeconds
        main_deadline_seconds=$Timing.MainDeadlineSeconds
        rollback_deadline_seconds=$Timing.RollbackDeadlineSeconds
        rollback_budget_seconds=$Timing.RollbackBudgetSeconds
        watchdog_safety_seconds=$Timing.WatchdogSafetySeconds
    }
}

$script:MaindEcmReadPairs = @(
    '60/65529', # AcceptedCommandList
    '60/0',     # WindowStatus
    '62/2',     # SupportedFabrics
    '62/3',     # CommissionedFabrics
    '62/5'      # CurrentFabricIndex
)

function New-MaindEcmContext {
    param(
        [Parameter(Mandatory=$true)][ValidateRange(1,[UInt64]::MaxValue)][UInt64]$ExpectedNodeId,
        [Parameter(Mandatory=$true)][ValidateRange(180,900)][int]$CommissioningTimeoutSeconds,
        [Parameter(Mandatory=$true)][ValidateRange(0,4095)][int]$Discriminator
    )
    if($ExpectedNodeId -eq 4660){throw 'Refusing demonstration Node ID 4660.'}
    [pscustomobject]@{
        ExpectedNodeId=$ExpectedNodeId
        ResolvedNodeId=[UInt64]0
        CommissioningTimeoutSeconds=$CommissioningTimeoutSeconds
        Discriminator=$Discriminator
        WindowPostClaimed=$false
        MatterCommissionClaimed=$false
    }
}

function Claim-MaindEcmMatterCommission {
    param(
        [Parameter(Mandatory=$true)]$Context,
        [Parameter(Mandatory=$true)][string]$ClaimPath
    )
    if($Context.MatterCommissionClaimed -or (Test-Path -LiteralPath $ClaimPath)){
        throw 'Matter.js commissioning already claimed; automatic retry is forbidden.'
    }
    [ordered]@{claimed=$true;claimed_utc=[DateTime]::UtcNow.ToString('o');command='commission_with_code';maximum_attempts=1}|
        ConvertTo-Json|Set-Content -Encoding utf8NoBOM -LiteralPath $ClaimPath
    $Context.MatterCommissionClaimed=$true
}

function Resolve-MaindEcmTargetFromDevices {
    param(
        [Parameter(Mandatory=$true)]$Context,
        [Parameter(Mandatory=$true)][string]$DevicesJson
    )
    $devices=@(ConvertFrom-Json -InputObject $DevicesJson -NoEnumerate -ErrorAction Stop)
    $candidates=@($devices|Where-Object{
        $null-ne$_.nodeId -and @($_.endpoints)-contains 0 -and @($_.endpoints)-contains 1
    })
    if($candidates.Count-ne1){throw "Expected exactly one /devices candidate with endpoints 0 and 1; found $($candidates.Count)."}
    $actual=[UInt64]$candidates[0].nodeId
    if($actual-ne[UInt64]$Context.ExpectedNodeId){
        throw "Target Node ID mismatch: expected $($Context.ExpectedNodeId), /devices returned $actual."
    }
    $Context.ResolvedNodeId=$actual
    return $actual
}

function Get-MaindEcmBaselineReadPlan {
    param([Parameter(Mandatory=$true)][UInt64]$NodeId)
    @(
        [pscustomobject]@{nodeId=$NodeId;clusterId=60;attributeId=65529;name='accepted_command_list';kind='list'},
        [pscustomobject]@{nodeId=$NodeId;clusterId=60;attributeId=0;name='window_status';kind='scalar'},
        [pscustomobject]@{nodeId=$NodeId;clusterId=62;attributeId=2;name='supported_fabrics';kind='scalar'},
        [pscustomobject]@{nodeId=$NodeId;clusterId=62;attributeId=3;name='commissioned_fabrics';kind='scalar'},
        [pscustomobject]@{nodeId=$NodeId;clusterId=62;attributeId=5;name='current_fabric_index';kind='scalar'}
    )
}

function Get-MaindEcmReadRequestJson {
    param([UInt64]$NodeId,[UInt64]$ClusterId,[UInt64]$AttributeId)
    ConvertTo-Json -Compress -InputObject ([ordered]@{
        nodeId=$NodeId;endpointId=0;clusterId=$ClusterId;attributeId=$AttributeId
    })
}

function Get-MaindEcmWindowRequestJson {
    param([Parameter(Mandatory=$true)]$Context)
    if([UInt64]$Context.ResolvedNodeId-eq0){throw 'Target must be resolved from /devices first.'}
    ConvertTo-Json -Compress -InputObject ([ordered]@{
        nodeId=[UInt64]$Context.ResolvedNodeId
        discriminator=[int]$Context.Discriminator
        timeout=[int]$Context.CommissioningTimeoutSeconds
    })
}

function Test-MaindEcmRequestAllowed {
    param(
        [Parameter(Mandatory=$true)]$Context,
        [Parameter(Mandatory=$true)][string]$Method,
        [Parameter(Mandatory=$true)][string]$Path,
        [AllowNull()][AllowEmptyString()][string]$RequestBody
    )
    if($Method-ceq'GET' -and $Path-ceq'/devices' -and [string]::IsNullOrEmpty($RequestBody)){return $true}
    if($Method-cne'POST' -or [string]::IsNullOrEmpty($RequestBody)){return $false}
    try{$body=ConvertFrom-Json $RequestBody -NoEnumerate -ErrorAction Stop}catch{return $false}
    $names=@($body.PSObject.Properties|ForEach-Object Name|Sort-Object)
    if($Path-ceq'/interaction/readAttribute'){
        if(($names-join',')-cne'attributeId,clusterId,endpointId,nodeId'){return $false}
        return [UInt64]$Context.ResolvedNodeId-ne0 -and [UInt64]$body.nodeId-eq[UInt64]$Context.ResolvedNodeId -and
            [UInt64]$body.endpointId-eq0 -and "$([UInt64]$body.clusterId)/$([UInt64]$body.attributeId)"-in$script:MaindEcmReadPairs
    }
    if($Path-ceq'/commissioning/window'){
        if($Context.WindowPostClaimed -or ($names-join',')-cne'discriminator,nodeId,timeout'){return $false}
        return [UInt64]$Context.ResolvedNodeId-ne0 -and [UInt64]$body.nodeId-eq[UInt64]$Context.ResolvedNodeId -and
            [int]$body.discriminator-eq[int]$Context.Discriminator -and
            [int]$body.timeout-eq[int]$Context.CommissioningTimeoutSeconds
    }
    return $false
}

function Assert-MaindEcmRequestAllowed {
    param($Context,[string]$Method,[string]$Path,[AllowNull()][string]$RequestBody)
    if(-not(Test-MaindEcmRequestAllowed $Context $Method $Path $RequestBody)){
        throw "HTTP request is not allowlisted for MultiAdminECM: $Method $Path"
    }
}

function Claim-MaindEcmWindowPost {
    param(
        [Parameter(Mandatory=$true)]$Context,
        [Parameter(Mandatory=$true)][string]$ClaimPath
    )
    if($Context.WindowPostClaimed -or (Test-Path -LiteralPath $ClaimPath)){
        throw 'OpenCommissioningWindow POST already claimed; automatic retry is forbidden.'
    }
    $parent=Split-Path -Parent $ClaimPath
    if($parent){New-Item -ItemType Directory -Force -Path $parent|Out-Null}
    [ordered]@{claimed=$true;claimed_utc=[DateTime]::UtcNow.ToString('o');route='/commissioning/window';maximum_posts=1}|
        ConvertTo-Json|Set-Content -Encoding utf8NoBOM -LiteralPath $ClaimPath
    $Context.WindowPostClaimed=$true
}

function ConvertFrom-MaindEcmWindowResponse {
    param([Parameter(Mandatory=$true)][string]$JsonText)
    $parsed=ConvertFrom-Json $JsonText -NoEnumerate -ErrorAction Stop
    $manual=[string]$parsed.manualCode;$qr=[string]$parsed.qrCode
    if([string]::IsNullOrWhiteSpace($manual) -or [string]::IsNullOrWhiteSpace($qr)){
        throw 'Commissioning window response is incomplete.'
    }
    if($manual-notmatch'^([0-9]{11}|[0-9]{21})$'){throw 'manualCode has an unexpected format.'}
    if($qr-notmatch'^MT:'){throw 'qrCode has an unexpected format.'}
    [pscustomobject]@{ManualCode=$manual;QrCode=$qr}
}

function Get-MaindEcmRedactedSummary {
    param([Parameter(Mandatory=$true)]$WindowResponse)
    [ordered]@{
        response_valid=$true
        manual_code_present=$true
        manual_code_length=([string]$WindowResponse.ManualCode).Length
        qr_code_present=$true
        qr_code_length=([string]$WindowResponse.QrCode).Length
        secrets_persisted=$false
    }
}

function Protect-MaindEcmDiagnosticText {
    param([AllowNull()][string]$Text)
    if($null-eq$Text){return $null}
    $safe=$Text -replace '(?i)(manualCode|qrCode|verifier|salt)\s*[=:]\s*[^\s,;}]+','$1=[REDACTED]'
    $safe=$safe -replace '\b[0-9]{11}\b','[REDACTED-MANUAL-CODE]'
    $safe=$safe -replace 'MT:[A-Z0-9+./_-]+','[REDACTED-QR-CODE]'
    return $safe
}

function Get-MatterWsIntegerValue {
    param(
        [Parameter(Mandatory=$true)]$Message,
        [Parameter(Mandatory=$true)][string]$Name
    )
    $property=Get-MatterWsProperty -Message $Message -Name $Name
    if($null-eq$property -or $null-eq$property.Value){return $null}
    [Int64]$value=0
    if(-not[Int64]::TryParse([string]$property.Value,[ref]$value)){return $null}
    return $value
}

function New-MatterJsCommissionErrorDiagnostic {
    param(
        [Parameter(Mandatory=$true)][AllowNull()]$Message,
        [Parameter(Mandatory=$true)][ValidateRange(0,[double]::MaxValue)][double]$ElapsedSeconds
    )
    $errorCode=$null;$status=$null;$clusterStatus=$null;$reason=$null
    if($null-ne$Message){
        $errorCode=Get-MatterWsIntegerValue -Message $Message -Name 'error_code'
        $status=Get-MatterWsIntegerValue -Message $Message -Name 'status'
        $clusterStatus=Get-MatterWsIntegerValue -Message $Message -Name 'cluster_status'
        $reasonProperty=Get-MatterWsProperty -Message $Message -Name 'reason'
        if($null-ne$reasonProperty -and $reasonProperty.Value-in@(
            'not-discovered','passcode-mismatch','invalid-payload','attestation-rejected','timeout','other'
        )){$reason=[string]$reasonProperty.Value}
    }

    # Version 1.5.5 supplies no explicit stage or "device discovered" field.
    # Derive only facts that its typed CommissionFailureReason makes certain.
    $stage=$null;$discovered='unknown'
    switch($reason){
        'invalid-payload' {$stage='payload-validation';$discovered='absent'}
        'not-discovered' {$stage='discovery';$discovered='absent'}
        'passcode-mismatch' {$stage='pase';$discovered='present'}
        'attestation-rejected' {$stage='device-attestation';$discovered='present'}
    }
    if($discovered-ceq'unknown' -and ($null-ne$status -or $null-ne$clusterStatus)){
        $stage='matter-status';$discovered='present'
    }

    [ordered]@{
        error_code=$errorCode
        reason=$reason
        status=$status
        cluster_status=$clusterStatus
        commissioning_stage=$stage
        elapsed_seconds=[Math]::Round($ElapsedSeconds,3)
        discovered_device=$discovered
    }
}
