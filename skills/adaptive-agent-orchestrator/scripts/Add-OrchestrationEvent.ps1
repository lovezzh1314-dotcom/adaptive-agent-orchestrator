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
    [string] $Artifact,
    [string] $Decision,
    [string] $HumanActor,
    [string[]] $Evidence = @(),
    [int] $Wave = 1,

    [ValidateSet('startup_unmaterialized', 'runtime_transient',
        'model_incompatible', 'permission_denied', 'task_invalid',
        'output_invalid', 'ownership_conflict', 'unknown')]
    [string] $ErrorClass
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
if ($Status -in @('failed', 'unknown') -and [string]::IsNullOrWhiteSpace($ErrorClass)) {
    throw "Status '$Status' requires ErrorClass."
}
if ($Status -notin @('failed', 'unknown') -and -not [string]::IsNullOrWhiteSpace($ErrorClass)) {
    throw "ErrorClass is only valid for failed or unknown status."
}
$cleanEvidence = @($Evidence | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_)
})
foreach ($entry in $cleanEvidence) {
    if ($entry -notmatch '^(artifact|test|source|observation):\S.+$') {
        throw "Evidence must use kind:value format: artifact, test, source, or observation."
    }
}
$requestFingerprint = Get-TextSha256 (
    [ordered]@{
        node_id = $NodeId
        status = $Status
        message = $Message
        thread_id = if ($ThreadId) { $ThreadId } else { $null }
        artifact = if ($Artifact) { $Artifact } else { $null }
        decision = if ($Decision) { $Decision } else { $null }
        human_actor = if ($HumanActor) { $HumanActor } else { $null }
        evidence = $cleanEvidence
        wave = $Wave
        error_class = if ($ErrorClass) { $ErrorClass } else { $null }
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
        $dependencySuccess = @('validated', 'adopted', 'archived')
        foreach ($dependency in @($node.depends_on)) {
            if ($latestStates[[string]$dependency] -notin $dependencySuccess) {
                throw "Node '$NodeId' cannot start before dependency '$dependency' is validated."
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
    $budgetDelta = 0
    if ($Status -eq 'launch_reserved') {
        $attempt++
        if ($attempt -gt [int]$node.max_attempts -or
            $attempt -gt [int]$plan.limits.max_attempts_per_node) {
            throw "Node '$NodeId' exceeds its attempt limit."
        }

        $launchEvents = @($events | Where-Object { $_.status -eq 'launch_reserved' })
        if ($launchEvents.Count -ge [int]$plan.limits.max_total_agent_nodes) {
            throw 'Total agent execution budget is exhausted.'
        }
        $retryEvents = @(
            $launchEvents | Group-Object node_id | ForEach-Object {
                [Math]::Max(0, $_.Count - 1)
            }
        )
        $retryCount = if ($retryEvents.Count) {
            ($retryEvents | Measure-Object -Sum).Sum
        } else { 0 }
        if ($priorState -eq 'failed' -and
            $retryCount -ge [int]$plan.limits.retry_reserve) {
            throw 'Retry reserve is exhausted.'
        }

        $latestByNode = @{}
        foreach ($event in $events | Where-Object { $null -ne $_.node_id }) {
            $latestByNode[[string]$event.node_id] = [string]$event.status
        }
        $activeStates = @(
            'launch_reserved', 'materializing', 'materialized', 'running', 'needs_input'
        )
        $activeCount = @(
            $latestByNode.Values | Where-Object { $_ -in $activeStates }
        ).Count
        if ($activeCount -ge [int]$plan.limits.max_concurrent_nodes) {
            throw 'Concurrent agent budget is exhausted.'
        }
        $waveCount = @(
            $launchEvents | Where-Object { [int]$_.wave -eq $Wave }
        ).Count
        if ($waveCount -ge [int]$plan.limits.max_new_nodes_per_wave) {
            throw "Wave $Wave exceeds max_new_nodes_per_wave."
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
            ($launchEvents.Count + 1)
        if ($remainingAfterLaunch -lt $unlaunchedVerification) {
            throw 'Launch would consume capacity reserved for planned verification nodes.'
        }
        $budgetDelta = 1
        if ($node.capability -eq 'ultra' -and
            $node.ultra_authorization -eq 'escalated-after-failure') {
            $priorNodeId = [string]$node.prior_attempt_node_id
            if ($latestStates[$priorNodeId] -notin @('failed', 'rejected')) {
                throw "Ultra escalation '$NodeId' requires failed prior node '$priorNodeId'."
            }
        }
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
        artifact = if ($Artifact) { $Artifact } else { $null }
        topology = if ($kind -eq 'agent') { $node.topology } else { $kind }
        capability = if ($kind -in @('agent', 'main')) { $node.capability } else { $null }
        effort = if ($kind -in @('agent', 'main')) { $node.effort } else { $null }
        wave = $Wave
        attempt = $attempt
        budget_delta = $budgetDelta
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
