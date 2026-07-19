[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RunDirectory,

    [Parameter(Mandatory)]
    [string] $NodeId,

    [Parameter(Mandatory)]
    [ValidateSet('launch_reserved', 'materializing', 'materialized', 'running',
        'needs_input', 'completed', 'validated', 'adopted', 'archived',
        'failed', 'cancelled', 'rejected', 'unknown')]
    [string] $Status,

    [Parameter(Mandatory)]
    [string] $Message,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $IdempotencyKey,

    [string] $ThreadId,
    [string] $ModelId,
    [string] $Artifact,
    [string] $Decision,
    [string] $HumanActor,
    [string[]] $Evidence = @(),
    [int] $Wave = 1,

    [ValidateRange(0, 1000000000)]
    [int64] $InputTokensDelta = 0,

    [ValidateRange(0, 1000000000)]
    [int64] $OutputTokensDelta = 0,

    [ValidateRange(0, 1000000000)]
    [int64] $CoordinationTokensDelta = 0,

    [ValidateSet('none', 'estimate', 'actual')]
    [string] $UsageSource = 'none',

    [ValidateSet('startup_unmaterialized', 'runtime_transient',
        'model_incompatible', 'permission_denied', 'task_invalid',
        'output_invalid', 'ownership_conflict', 'unknown')]
    [string] $ErrorClass,

    [string] $ActionKey,
    [string] $PremiseManifestPath,
    [string] $FailureCode,
    [string] $RetryAuthorization,
    [string] $ReconciliationReceiptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')

$planPath = Join-Path $RunDirectory 'plan.json'
$eventsPath = Join-Path $RunDirectory 'events.jsonl'
$runPath = Join-Path $RunDirectory 'run.json'
if (-not (Test-Path -LiteralPath $planPath) -or
    -not (Test-Path -LiteralPath $eventsPath) -or
    -not (Test-Path -LiteralPath $runPath)) {
    throw "Run directory is missing plan.json, run.json, or events.jsonl: $RunDirectory"
}
$planText = Get-Content -LiteralPath $planPath -Raw
$plan = $planText | ConvertFrom-Json -Depth 100
$runMetadata = Get-Content -LiteralPath $runPath -Raw | ConvertFrom-Json -Depth 20
$node = @($plan.nodes | Where-Object { $_.id -eq $NodeId }) | Select-Object -First 1
if ($null -eq $node) { throw "Unknown node id '$NodeId'." }
$effectiveWave = if ($node.kind -eq 'agent') {
    [int]$node.wave
} else {
    $Wave
}
if ($Status -in @('failed', 'unknown') -and [string]::IsNullOrWhiteSpace($ErrorClass)) {
    throw "Status '$Status' requires ErrorClass."
}
if ($Status -notin @('failed', 'unknown') -and -not [string]::IsNullOrWhiteSpace($ErrorClass)) {
    throw "ErrorClass is only valid for failed or unknown status."
}
if ($ModelId -and $ModelId -notin @(
    'gpt-5.6-luna', 'gpt-5.6-sol', 'gpt-5.6-terra'
)) {
    throw "Unsupported actual model '$ModelId'."
}
if ($node.kind -eq 'agent' -and $Status -eq 'materialized') {
    if ([string]::IsNullOrWhiteSpace($ModelId)) {
        throw 'Agent materialization requires the actual ModelId.'
    }
    if ($ModelId -ne [string]$node.model) {
        throw (
            "Actual model '$ModelId' differs from planned model " +
            "'$($node.model)'; obtain confirmation and create a revised plan."
        )
    }
}
$usageDelta = $InputTokensDelta + $OutputTokensDelta
if ($CoordinationTokensDelta -gt $usageDelta) {
    throw 'Coordination Token delta must be a subset of input plus output Tokens.'
}
if ($UsageSource -eq 'none' -and $usageDelta -gt 0) {
    throw 'Token deltas require UsageSource estimate or actual.'
}
if ($UsageSource -ne 'none' -and $usageDelta -eq 0) {
    throw 'UsageSource estimate or actual requires a non-zero Token delta.'
}
$cleanEvidence = @($Evidence | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_)
})
$deterministicFailureClasses = @(
    'model_incompatible', 'permission_denied', 'task_invalid',
    'output_invalid', 'ownership_conflict'
)
$normalizedActionKey = if ([string]::IsNullOrWhiteSpace($ActionKey)) {
    $null
} else {
    $ActionKey.Trim()
}
$premiseFingerprint = $null
$premiseRelativePath = $null
if (-not [string]::IsNullOrWhiteSpace($PremiseManifestPath)) {
    if ([IO.Path]::IsPathRooted($PremiseManifestPath)) {
        throw 'PremiseManifestPath must be relative to the run directory.'
    }
    $premiseSegments = $PremiseManifestPath -split '[\\/]'
    if (@($premiseSegments | Where-Object {
        $_ -in @('', '.', '..') -or $_ -match '[\. ]$' -or $_.Contains(':')
    }).Count -gt 0) {
        throw 'PremiseManifestPath is unsafe.'
    }
    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $resolvedPremisePath = [IO.Path]::GetFullPath(
        (Join-Path $runRoot $PremiseManifestPath)
    )
    if (-not $resolvedPremisePath.StartsWith(
        $runRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    ) -or -not (Test-Path -LiteralPath $resolvedPremisePath -PathType Leaf)) {
        throw 'Premise manifest must be an existing file inside the run.'
    }
    $cursor = Split-Path -Parent $resolvedPremisePath
    while ($cursor.StartsWith(
        $runRoot,
        [StringComparison]::OrdinalIgnoreCase
    ) -and $cursor.Length -ge $runRoot.Length) {
        if (((Get-Item -LiteralPath $cursor).Attributes -band
            [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Premise manifest cannot cross a link or reparse point.'
        }
        if ($cursor -eq $runRoot) { break }
        $cursor = Split-Path -Parent $cursor
    }
    $premise = Get-Content -LiteralPath $resolvedPremisePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 30
    foreach ($requiredPremiseField in @(
        'schema_version', 'node_id', 'action_key', 'input_refs',
        'repair_instruction'
    )) {
        if (-not $premise.ContainsKey($requiredPremiseField)) {
            throw "Premise manifest is missing '$requiredPremiseField'."
        }
    }
    if ([string]$premise.schema_version -ne '1.0' -or
        [string]$premise.node_id -ne $NodeId -or
        ([string]$premise.action_key).Trim() -ne $normalizedActionKey -or
        [string]::IsNullOrWhiteSpace([string]$premise.repair_instruction)) {
        throw 'Premise manifest does not match the current node and action.'
    }
    $premiseInputRefs = @($premise.input_refs | ForEach-Object {
        ([string]$_).Trim()
    } | Sort-Object -Unique)
    if ($premiseInputRefs.Count -eq 0 -or
        @($premiseInputRefs | Where-Object {
            $_ -notmatch '^(artifact|test|source|observation):\S.+$'
        }).Count -gt 0) {
        throw 'Premise manifest requires typed, non-empty input_refs.'
    }
    $canonicalPremise = [ordered]@{
        schema_version = '1.0'
        node_id = [string]$premise.node_id
        action_key = $normalizedActionKey
        input_refs = $premiseInputRefs
        repair_instruction = [regex]::Replace(
            ([string]$premise.repair_instruction).Trim(),
            '\s+',
            ' '
        )
    }
    $premiseFingerprint = Get-TextSha256 (
        $canonicalPremise | ConvertTo-Json -Compress -Depth 10
    )
    $premiseRelativePath = $PremiseManifestPath.Replace('\', '/')
}
if (-not [string]::IsNullOrWhiteSpace($FailureCode) -and
    $FailureCode -notmatch '^[a-z0-9][a-z0-9._-]{0,63}$') {
    throw 'FailureCode must be a stable lowercase code.'
}
if ($Status -eq 'failed' -and
    $ErrorClass -in $deterministicFailureClasses) {
    if ([string]::IsNullOrWhiteSpace($ActionKey) -or
        [string]::IsNullOrWhiteSpace($premiseFingerprint) -or
        [string]::IsNullOrWhiteSpace($FailureCode)) {
        throw (
            'Deterministic failures require ActionKey, PremiseManifestPath, ' +
            'and FailureCode.'
        )
    }
}
$actionHash = if ([string]::IsNullOrWhiteSpace($normalizedActionKey)) {
    $null
} else {
    Get-TextSha256 $normalizedActionKey
}
if ($actionHash) {
    $cleanEvidence += "observation:action-key:$actionHash"
}
if (-not [string]::IsNullOrWhiteSpace($premiseFingerprint)) {
    $cleanEvidence += "artifact:premise-manifest:$premiseRelativePath"
    $cleanEvidence += (
        'observation:premise-fingerprint:' +
        $premiseFingerprint
    )
}
if (-not [string]::IsNullOrWhiteSpace($FailureCode)) {
    $cleanEvidence += "observation:failure-code:$FailureCode"
}
if ($Status -eq 'failed' -and
    $ErrorClass -in $deterministicFailureClasses) {
    $failureFingerprint = Get-TextSha256 (
        "$actionHash|$premiseFingerprint|" +
        "$ErrorClass|$FailureCode"
    )
    $cleanEvidence += "observation:failure-fingerprint:$failureFingerprint"
}
if (-not [string]::IsNullOrWhiteSpace($RetryAuthorization)) {
    $cleanEvidence += "source:retry-authorization:$RetryAuthorization"
}
$reconciliationReceipt = $null
if (-not [string]::IsNullOrWhiteSpace($ReconciliationReceiptPath)) {
    if ([IO.Path]::IsPathRooted($ReconciliationReceiptPath)) {
        throw 'ReconciliationReceiptPath must be relative to the run directory.'
    }
    $reconciliationReceipt = Read-ThreadReconciliationReceipt -Path (
        Join-Path $RunDirectory $ReconciliationReceiptPath
    ) -RunDirectory $RunDirectory -ExpectedDecision 'no_match'
    $normalizedReconciliationPath = $ReconciliationReceiptPath.Replace('\', '/')
    $cleanEvidence += (
        "artifact:thread-reconciliation:$normalizedReconciliationPath"
    )
    $cleanEvidence += (
        'observation:thread-reconciliation-hash:' +
        [string]$reconciliationReceipt.receipt_hash
    )
    $cleanEvidence += 'observation:task-list-reconciled-no-match'
}
foreach ($entry in $cleanEvidence) {
    if ($entry -notmatch '^(artifact|test|source|observation):\S.+$') {
        throw "Evidence must use kind:value format: artifact, test, source, or observation."
    }
}
if ($Status -eq 'failed' -and $ErrorClass -eq 'startup_unmaterialized' -and
    $null -eq $reconciliationReceipt) {
    throw (
        'startup_unmaterialized requires a verified no-match ' +
        'ReconciliationReceiptPath.'
    )
}
$requestFingerprint = Get-TextSha256 (
    [ordered]@{
        node_id = $NodeId
        status = $Status
        message = $Message
        thread_id = if ($ThreadId) { $ThreadId } else { $null }
        model_id = if ($ModelId) { $ModelId } else { $null }
        artifact = if ($Artifact) { $Artifact } else { $null }
        decision = if ($Decision) { $Decision } else { $null }
        human_actor = if ($HumanActor) { $HumanActor } else { $null }
        evidence = $cleanEvidence
        wave = $effectiveWave
        error_class = if ($ErrorClass) { $ErrorClass } else { $null }
        input_tokens_delta = $InputTokensDelta
        output_tokens_delta = $OutputTokensDelta
        coordination_tokens_delta = $CoordinationTokensDelta
        usage_source = $UsageSource
    } | ConvertTo-Json -Compress -Depth 10
)

$transitions = @{
    planned = @('launch_reserved', 'running', 'needs_input', 'completed', 'cancelled')
    launch_reserved = @('materializing', 'failed', 'cancelled', 'unknown')
    materializing = @('materialized', 'failed', 'cancelled', 'unknown')
    materialized = @('running', 'failed', 'cancelled')
    running = @('needs_input', 'completed', 'failed', 'cancelled', 'unknown')
    needs_input = @('running', 'completed', 'failed', 'cancelled', 'unknown')
    completed = @('validated', 'rejected')
    validated = @('adopted', 'rejected')
    adopted = @('archived')
    failed = @('launch_reserved', 'rejected')
    unknown = @('rejected')
    cancelled = @()
    rejected = @()
    archived = @()
}

$mutex = [Threading.Mutex]::new($false, (Get-JournalMutexName $eventsPath))
try {
    if (-not $mutex.WaitOne([TimeSpan]::FromSeconds(10))) {
        throw 'Timed out waiting for the orchestration journal lock.'
    }
    $events = @(Read-OrchestrationJournal $eventsPath)
    $currentPlanHash = Get-TextSha256 (
        Get-Content -LiteralPath $planPath -Raw
    )
    if ($currentPlanHash -ne $runMetadata.plan_hash -or
        $events[0].plan_hash -ne $runMetadata.plan_hash) {
        throw 'plan.json or run metadata changed after run creation.'
    }
    if ($runMetadata.run_id -ne $plan.run_id -or
        $runMetadata.policy_version -ne $plan.policy_version -or
        $events[0].run_id -ne $runMetadata.run_id -or
        $events[0].policy_version -ne $runMetadata.policy_version) {
        throw 'run.json metadata is inconsistent with the immutable plan or journal.'
    }
    if ($events[0].workspace_root -ne $runMetadata.workspace_root) {
        throw 'Workspace root changed after run creation.'
    }

    $history = @($events | Where-Object { $_.node_id -eq $NodeId })
    $priorState = if ($history.Count) { [string]$history[-1].status } else { 'planned' }
    $existing = @(
        $events | Where-Object { $_.idempotency_key -eq $IdempotencyKey }
    ) | Select-Object -First 1
    if ($null -ne $existing) {
        if ($existing.node_id -ne $NodeId -or $existing.status -ne $Status -or
            $existing.request_fingerprint -ne $requestFingerprint) {
            throw "IdempotencyKey '$IdempotencyKey' was already used for another event."
        }
        $existing | ConvertTo-Json -Depth 10
        return
    }

    if ($Status -notin @($transitions[$priorState])) {
        throw "Illegal state transition for '$NodeId': $priorState -> $Status."
    }

    $latestStates = @{}
    foreach ($planNode in $plan.nodes) { $latestStates[$planNode.id] = 'planned' }
    foreach ($journalEvent in $events | Where-Object { $null -ne $_.node_id }) {
        $latestStates[[string]$journalEvent.node_id] = [string]$journalEvent.status
    }
    if ($priorState -eq 'planned') {
        $dependencySuccess = @('adopted', 'archived')
        foreach ($dependency in @($node.depends_on)) {
            if ($latestStates[[string]$dependency] -notin $dependencySuccess) {
                throw "Node '$NodeId' cannot start before dependency '$dependency' is adopted."
            }
        }
        if ($node.kind -eq 'agent' -and $Status -eq 'launch_reserved') {
            $earlierWaveTerminal = @('adopted', 'archived', 'rejected', 'cancelled')
            foreach ($earlierNode in @($plan.nodes | Where-Object {
                $_.kind -eq 'agent' -and [int]$_.wave -lt [int]$node.wave
            })) {
                if ($latestStates[[string]$earlierNode.id] -notin $earlierWaveTerminal) {
                    throw "Node '$NodeId' cannot start before earlier-wave node '$($earlierNode.id)' reaches a terminal state."
                }
            }
        }
    }

    $kind = [string]$node.kind
    if ($kind -eq 'agent' -and $priorState -eq 'planned' -and $Status -ne 'launch_reserved') {
        throw "Agent node '$NodeId' must reserve capacity before launch."
    }
    if ($kind -eq 'main' -and $priorState -eq 'planned' -and
        $Status -notin @('running', 'cancelled')) {
        throw "Main node '$NodeId' must enter running before completion."
    }
    if ($kind -eq 'human-gate' -and $priorState -eq 'planned' -and
        $Status -notin @('needs_input', 'cancelled')) {
        throw "Human gate '$NodeId' must enter needs_input before completion."
    }
    if ($kind -eq 'join' -and $priorState -eq 'planned' -and
        $Status -notin @('completed', 'cancelled')) {
        throw "Join node '$NodeId' may only complete after its dependencies."
    }
    if ($kind -ne 'agent' -and $Status -in @(
        'launch_reserved', 'materializing', 'materialized'
    )) {
        throw "Only agent nodes use launch lifecycle states."
    }
    if ($kind -eq 'agent' -and $Status -eq 'materialized' -and
        [string]::IsNullOrWhiteSpace($ThreadId)) {
        throw "Materialized agent node '$NodeId' requires ThreadId."
    }
    if ($kind -eq 'agent' -and $Status -eq 'materialized') {
        if ($node.context.session_policy -eq 'fresh') {
            $alreadyUsed = @($events | Where-Object {
                $_.thread_id -eq $ThreadId
            }).Count -gt 0
            if ($alreadyUsed) {
                throw "Fresh agent node '$NodeId' cannot reuse thread '$ThreadId'."
            }
        } elseif ($ThreadId -ne $node.context.prior_thread_id) {
            throw "Reuse agent node '$NodeId' must materialize its declared prior_thread_id."
        }
    }
    if ($kind -eq 'human-gate' -and $Status -eq 'completed') {
        if ([string]::IsNullOrWhiteSpace($Decision) -or
            [string]::IsNullOrWhiteSpace($HumanActor)) {
            throw "Human gate '$NodeId' completion requires Decision and HumanActor."
        }
        if ($Decision -notin @($node.choices)) {
            throw "Human gate '$NodeId' decision '$Decision' is not an allowed choice."
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($Decision) -or
        -not [string]::IsNullOrWhiteSpace($HumanActor)) {
        throw 'Decision and HumanActor are only valid when completing a human gate.'
    }
    if ($kind -in @('agent', 'main') -and $Status -eq 'needs_input') {
        $role = @($plan.roles | Where-Object { $_.id -eq $node.role_id }) |
            Select-Object -First 1
        $priorQuestions = @($history | Where-Object { $_.status -eq 'needs_input' }).Count
        if ($priorQuestions -ge [int]$role.question_policy.max_questions) {
            throw "Node '$NodeId' exceeds role '$($node.role_id)' question limit."
        }
    }
    if ($kind -in @('agent', 'main') -and $Status -eq 'completed' -and
        $cleanEvidence.Count -eq 0) {
        throw "Node '$NodeId' completion requires at least one Evidence entry."
    }

    $attempt = @($history | Where-Object { $_.status -eq 'launch_reserved' }).Count
    $executionSlotDelta = 0
    if ($Status -eq 'launch_reserved') {
        $attempt++
        if ($attempt -gt [int]$node.max_attempts -or
            $attempt -gt [int]$plan.limits.max_attempts_per_node) {
            throw "Node '$NodeId' exceeds its attempt limit."
        }

        $launchEvents = @($events | Where-Object { $_.status -eq 'launch_reserved' })
        $latestByNode = @{}
        foreach ($event in $events | Where-Object { $null -ne $_.node_id }) {
            $latestByNode[[string]$event.node_id] = [string]$event.status
        }
        $pendingStates = @('launch_reserved', 'materializing')
        $pendingCount = @(
            $latestByNode.Values | Where-Object { $_ -in $pendingStates }
        ).Count
        $materializedCount = @(
            $events | Where-Object { $_.status -eq 'materialized' }
        ).Count
        $occupiedWorkerSlots = $pendingCount + $materializedCount
        if ($occupiedWorkerSlots -ge [int]$plan.limits.max_total_agent_nodes) {
            throw 'Total agent execution slots are exhausted.'
        }
        $retryCount = 0
        foreach ($nodeEvents in @(
            $events | Where-Object { $null -ne $_.node_id } |
                Group-Object node_id
        )) {
            $attemptSeen = $false
            $attemptMaterialized = $false
            foreach ($nodeEvent in @($nodeEvents.Group)) {
                if ($nodeEvent.status -eq 'launch_reserved') {
                    if ($attemptSeen -and $attemptMaterialized) {
                        $retryCount++
                    }
                    $attemptSeen = $true
                    $attemptMaterialized = $false
                } elseif ($nodeEvent.status -eq 'materialized') {
                    $attemptMaterialized = $true
                }
            }
        }
        if ($priorState -eq 'failed' -and
            $retryCount -ge [int]$plan.limits.retry_reserve) {
            $lastFailure = @(
                $history | Where-Object { $_.status -eq 'failed' }
            ) | Select-Object -Last 1
            if ($lastFailure.error_class -ne 'startup_unmaterialized') {
                throw 'Retry reserve is exhausted.'
            }
        }
        if ($priorState -eq 'failed') {
            $lastFailure = @(
                $history | Where-Object { $_.status -eq 'failed' }
            ) | Select-Object -Last 1
            if ($lastFailure.error_class -eq 'startup_unmaterialized' -and
                'observation:task-list-reconciled-no-match' -notin
                @($lastFailure.evidence)) {
                throw 'Startup retry requires task-list reconciliation evidence.'
            }
            if ($lastFailure.error_class -eq 'startup_unmaterialized') {
                $reconciliationArtifact = @(
                    $lastFailure.evidence | Where-Object {
                        $_ -like 'artifact:thread-reconciliation:*'
                    }
                ) | Select-Object -Last 1
                $reconciliationHashEvidence = @(
                    $lastFailure.evidence | Where-Object {
                        $_ -like 'observation:thread-reconciliation-hash:*'
                    }
                ) | Select-Object -Last 1
                if ([string]::IsNullOrWhiteSpace(
                    [string]$reconciliationArtifact
                ) -or [string]::IsNullOrWhiteSpace(
                    [string]$reconciliationHashEvidence
                )) {
                    throw 'Startup retry lacks a bound reconciliation receipt.'
                }
                $relativeReconciliationPath = (
                    [string]$reconciliationArtifact
                ).Substring('artifact:thread-reconciliation:'.Length)
                $verifiedReconciliation = Read-ThreadReconciliationReceipt `
                    -Path (Join-Path $RunDirectory $relativeReconciliationPath) `
                    -RunDirectory $RunDirectory -ExpectedDecision 'no_match'
                if ([string]$reconciliationHashEvidence -ne (
                    'observation:thread-reconciliation-hash:' +
                    [string]$verifiedReconciliation.receipt_hash
                )) {
                    throw 'Startup retry reconciliation receipt was changed.'
                }
            }
            if ($lastFailure.error_class -in $deterministicFailureClasses) {
                if ([string]::IsNullOrWhiteSpace($ActionKey) -or
                    [string]::IsNullOrWhiteSpace($premiseFingerprint)) {
                    throw (
                        'Retry after a deterministic failure requires ' +
                        'ActionKey and PremiseManifestPath.'
                    )
                }
                $requiredAuthorization = "user:$($lastFailure.hash)"
                if ($RetryAuthorization -ne $requiredAuthorization) {
                    throw (
                        'Retry after a deterministic failure requires ' +
                        "explicit authorization '$requiredAuthorization'."
                    )
                }
                $authorizationEvidence = (
                    "source:retry-authorization:$requiredAuthorization"
                )
                if (@($events | Where-Object {
                    $authorizationEvidence -in @($_.evidence)
                }).Count -gt 0) {
                    throw 'Retry authorization was already consumed.'
                }
            }
        }

        $activeStates = @(
            'launch_reserved', 'materializing', 'materialized', 'running', 'needs_input'
        )
        $activeNodeIds = @(
            $latestByNode.GetEnumerator() | Where-Object {
                $_.Value -in $activeStates
            } | ForEach-Object { $_.Key }
        )
        $activeCount = $activeNodeIds.Count
        if ($activeCount -ge [int]$plan.limits.max_concurrent_nodes) {
            throw 'Concurrent agent slots are exhausted.'
        }
        if ($node.topology -eq 'background-thread') {
            $activePersistentCount = @(
                $plan.nodes | Where-Object {
                    $_.kind -eq 'agent' -and
                    $_.topology -eq 'background-thread' -and
                    $_.id -in $activeNodeIds
                }
            ).Count
            if ($activePersistentCount -ge
                [int]$plan.limits.persistent_active_limit) {
                throw 'Persistent active Worker limit is exhausted.'
            }
        }
        $waveCount = @(
            $launchEvents | Where-Object { [int]$_.wave -eq $effectiveWave }
        ).Count
        if ($waveCount -ge [int]$plan.limits.max_new_nodes_per_wave) {
            throw "Wave $effectiveWave exceeds max_new_nodes_per_wave."
        }

        $launchedNodeIds = @($launchEvents | ForEach-Object { $_.node_id })
        $unlaunchedVerification = @(
            $plan.nodes | Where-Object {
                $_.kind -eq 'agent' -and $_.purpose -eq 'verification' -and
                $_.id -ne $NodeId -and
                $_.id -notin $launchedNodeIds
            }
        ).Count
        $remainingAfterLaunch = [int]$plan.limits.max_total_agent_nodes -
            ($occupiedWorkerSlots + 1)
        if ($remainingAfterLaunch -lt $unlaunchedVerification) {
            throw 'Launch would consume capacity reserved for planned verification nodes.'
        }
        $executionSlotDelta = 1
    }

    $event = [ordered]@{
        sequence = $events.Count
        prev_hash = if ($events.Count) { $events[-1].hash } else { $null }
        timestamp = [DateTimeOffset]::UtcNow.ToString('o')
        event = 'node-status'
        run_id = $plan.run_id
        plan_hash = $runMetadata.plan_hash
        workspace_root = $runMetadata.workspace_root
        policy_version = $plan.policy_version
        actor = $plan.orchestrator.id
        node_id = $NodeId
        role_id = if ($kind -in @('agent', 'main')) { $node.role_id } else { $null }
        prior_state = $priorState
        status = $Status
        message = $Message
        thread_id = if ($ThreadId) { $ThreadId } else { $null }
        model_id = if ($ModelId) { $ModelId } else { $null }
        artifact = if ($Artifact) { $Artifact } else { $null }
        topology = if ($kind -eq 'agent') { $node.topology } else { $kind }
        capability = if ($kind -in @('agent', 'main')) { $node.capability } else { $null }
        effort = if ($kind -in @('agent', 'main')) { $node.effort } else { $null }
        wave = $effectiveWave
        attempt = $attempt
        execution_slot_delta = $executionSlotDelta
        input_tokens_delta = $InputTokensDelta
        output_tokens_delta = $OutputTokensDelta
        coordination_tokens_delta = $CoordinationTokensDelta
        usage_source = $UsageSource
        error_class = if ($ErrorClass) { $ErrorClass } else { $null }
        decision = if ($Decision) { $Decision } else { $null }
        human_actor = if ($HumanActor) { $HumanActor } else { $null }
        evidence = $cleanEvidence
        idempotency_key = $IdempotencyKey
        request_fingerprint = $requestFingerprint
    }
    $event.hash = Get-OrchestrationEventHash ([pscustomobject]$event)
    Add-Content -LiteralPath $eventsPath -Value ($event | ConvertTo-Json -Compress)
}
finally {
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}

$event | ConvertTo-Json -Depth 10
