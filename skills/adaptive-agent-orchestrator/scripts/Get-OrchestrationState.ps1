[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RunDirectory
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
$events = @(Read-OrchestrationJournal $eventsPath)
if ((Get-TextSha256 $planText) -ne $runMetadata.plan_hash -or
    $events[0].plan_hash -ne $runMetadata.plan_hash) {
    throw 'plan.json or run metadata changed after run creation.'
}
if ($runMetadata.run_id -ne $plan.run_id -or
    $runMetadata.policy_version -ne $plan.policy_version -or
    $events[0].run_id -ne $runMetadata.run_id -or
    $events[0].policy_version -ne $runMetadata.policy_version -or
    $events[0].workspace_root -ne $runMetadata.workspace_root) {
    throw 'run.json metadata is inconsistent with the immutable plan or journal.'
}
$retryUsed = 0
$nodeStates = foreach ($node in $plan.nodes) {
    $history = @($events | Where-Object { $_.node_id -eq $node.id })
    $latest = $history | Select-Object -Last 1
    $lastThread = $history | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.thread_id)
    } | Select-Object -Last 1
    $lastArtifact = $history | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.artifact)
    } | Select-Object -Last 1
    $lastError = $history | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.error_class)
    } | Select-Object -Last 1
    $evidence = @(
        $history | ForEach-Object { @($_.evidence) } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Select-Object -Unique
    )
    $attempts = @($history | Where-Object { $_.status -eq 'launch_reserved' }).Count
    $retryUsed += [Math]::Max(0, $attempts - 1)
    [pscustomobject]@{
        id = $node.id
        kind = $node.kind
        role_id = if ($node.kind -in @('agent', 'main')) { $node.role_id } else { $null }
        purpose = if ($node.kind -eq 'agent') { $node.purpose } else { $null }
        wave = if ($node.kind -eq 'agent') { [int]$node.wave } else { $null }
        dependencies = @($node.depends_on)
        status = if ($latest) { $latest.status } else { 'planned' }
        thread_id = if ($lastThread) { $lastThread.thread_id } else { $null }
        artifact = if ($lastArtifact) { $lastArtifact.artifact } else { $null }
        attempts = $attempts
        latest_message = if ($latest) { $latest.message } else { $null }
        error_class = if ($lastError) { $lastError.error_class } else { $null }
        evidence = $evidence
    }
}

$terminalSuccess = @('adopted', 'archived')
$waveTerminal = @('adopted', 'archived', 'rejected', 'cancelled')
$openAgentWaves = @(
    $nodeStates | Where-Object {
        $_.kind -eq 'agent' -and $_.status -notin $waveTerminal
    } | ForEach-Object { [int]$_.wave }
)
$earliestOpenWave = if ($openAgentWaves.Count) {
    ($openAgentWaves | Measure-Object -Minimum).Minimum
} else { $null }
$inputTokens = @($events | Measure-Object -Property input_tokens_delta -Sum).Sum
$outputTokens = @($events | Measure-Object -Property output_tokens_delta -Sum).Sum
$coordinationTokens = @(
    $events | Measure-Object -Property coordination_tokens_delta -Sum
).Sum
$totalTokens = [int64]$inputTokens + [int64]$outputTokens
$ready = @(
    $nodeStates | Where-Object {
        $_.status -eq 'planned' -and
        ($_.kind -ne 'agent' -or [int]$_.wave -eq [int]$earliestOpenWave) -and
        (@($_.dependencies | Where-Object {
            $dependency = $_
            ($nodeStates | Where-Object { $_.id -eq $dependency }).status -notin $terminalSuccess
        }).Count -eq 0)
    } | Select-Object -ExpandProperty id
)

$state = [ordered]@{
    schema_version = '1.0'
    policy_version = $plan.policy_version
    run_id = $plan.run_id
    plan_hash = $runMetadata.plan_hash
    workspace_root = $runMetadata.workspace_root
    generated_at = [DateTimeOffset]::UtcNow.ToString('o')
    journal_events = $events.Count
    journal_head = if ($events.Count) { $events[-1].hash } else { $null }
    launch_attempts = @($events | Where-Object { $_.status -eq 'launch_reserved' }).Count
    materialized_workers = @(
        $events | Where-Object { $_.status -eq 'materialized' }
    ).Count
    retry_attempts = $retryUsed
    ready_nodes = $ready
    usage = [ordered]@{
        telemetry = if (@($events | Where-Object {
            $_.usage_source -eq 'actual'
        }).Count) { 'actual-or-mixed' } else { 'estimate' }
        input_tokens = [int64]$inputTokens
        output_tokens = [int64]$outputTokens
        coordination_tokens = [int64]$coordinationTokens
        total_tokens = $totalTokens
    }
    nodes = @($nodeStates)
}

$statePath = Join-Path $RunDirectory 'state.json'
$state | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath
$state | ConvertTo-Json -Depth 20
