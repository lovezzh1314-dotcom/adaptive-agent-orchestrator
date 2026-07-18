[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $PlanPath,
    [Parameter(Mandatory)][string] $NodeId,
    [Parameter(Mandatory)][string] $WorkspaceRoot,
    [string] $OutputPath,
    [string] $RetryOutputRef,
    [string] $FailureEvidence,
    [string] $RepairInstruction,
    [string] $RetryRunDirectory,
    [switch] $Full
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')

& (Join-Path $scriptRoot 'Test-OrchestrationPlan.ps1') `
    -PlanPath $PlanPath -WorkspaceRoot $WorkspaceRoot | Out-Null
$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json -Depth 100
$node = @($plan.nodes | Where-Object { $_.id -eq $NodeId }) | Select-Object -First 1
if ($null -eq $node) { throw "Unknown node id '$NodeId'." }
if ($node.kind -ne 'agent') {
    throw "Worker packets can only be rendered for agent nodes: '$NodeId'."
}
$role = @($plan.roles | Where-Object { $_.id -eq $node.role_id }) |
    Select-Object -First 1
$retryValues = @($RetryOutputRef, $FailureEvidence, $RepairInstruction)
$isDeltaRetry = @($retryValues | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_)
}).Count -gt 0
if ($isDeltaRetry -and @($retryValues | Where-Object {
    [string]::IsNullOrWhiteSpace($_)
}).Count -gt 0) {
    throw 'Delta retry requires RetryOutputRef, FailureEvidence, and RepairInstruction.'
}
if ($isDeltaRetry -and [string]::IsNullOrWhiteSpace($RetryRunDirectory)) {
    throw 'Delta retry requires RetryRunDirectory from the failed execution.'
}
if (-not $isDeltaRetry -and -not [string]::IsNullOrWhiteSpace($RetryRunDirectory)) {
    throw 'RetryRunDirectory is only valid for delta retry.'
}
if ($isDeltaRetry -and $Full) {
    throw 'Delta retry cannot use Full packet mode.'
}
if ($isDeltaRetry) {
    if (-not (Test-Path -LiteralPath $RetryRunDirectory -PathType Container)) {
        throw "Delta retry run directory does not exist: '$RetryRunDirectory'."
    }
    $retryState = & (Join-Path $scriptRoot 'Get-OrchestrationState.ps1') `
        -RunDirectory $RetryRunDirectory | ConvertFrom-Json -Depth 100
    $suppliedPlanHash = Get-TextSha256 (
        Get-Content -LiteralPath $PlanPath -Raw
    )
    if ([string]$retryState.plan_hash -ne $suppliedPlanHash) {
        throw 'Delta retry plan does not match the failed execution plan.'
    }
    $retryNode = @($retryState.nodes | Where-Object { $_.id -eq $NodeId }) |
        Select-Object -First 1
    if ($null -eq $retryNode -or [string]$retryNode.status -ne 'failed') {
        throw "Delta retry requires node '$NodeId' to be in failed state."
    }
}

function Join-Bullets {
    param([object[]] $Items)
    return (@($Items) | ForEach-Object { "- $_" }) -join [Environment]::NewLine
}

$scopeText = if ($node.read_only) {
    '- No workspace writes; return findings in the task response.'
} else {
    Join-Bullets @($node.write_scope)
}
$dependencies = if (@($node.depends_on).Count) {
    @($node.depends_on) -join ', '
} else { 'none' }
$contextInputs = Join-Bullets @($node.context.inputs)
$contextReferences = Join-Bullets @($node.context.inputs)
$excludedContext = Join-Bullets @($node.context.excluded)
$priorContext = if ($node.context.session_policy -eq 'reuse') {
    $root = (Resolve-Path -LiteralPath $WorkspaceRoot).Path.TrimEnd('\', '/')
    $relativeHandoff = [string]$node.context.prior_handoff
    $segments = $relativeHandoff -split '[\\/]'
    if ([IO.Path]::IsPathRooted($relativeHandoff) -or
        @($segments | Where-Object {
            $_ -in @('', '.', '..') -or $_ -match '[\. ]$' -or $_.Contains(':')
        }).Count -gt 0) {
        throw "Unsafe prior_handoff path: '$relativeHandoff'."
    }
    $priorHandoffPath = [IO.Path]::GetFullPath((Join-Path $root $relativeHandoff))
    if (-not $priorHandoffPath.StartsWith(
        $root + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "prior_handoff escapes WorkspaceRoot: '$relativeHandoff'."
    }
    $cursor = $root
    foreach ($segment in $segments) {
        $cursor = Join-Path $cursor $segment
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "prior_handoff crosses a link or reparse point: '$relativeHandoff'."
            }
        }
    }
    if (-not (Test-Path -LiteralPath $priorHandoffPath -PathType Leaf)) {
        throw "prior_handoff does not exist: '$relativeHandoff'."
    }
    $actualHandoffHash = Get-TextSha256 (
        Get-Content -LiteralPath $priorHandoffPath -Raw
    )
    if ($actualHandoffHash -ne [string]$node.context.prior_handoff_hash) {
        throw "prior_handoff_hash does not match '$relativeHandoff'."
    }
    @"
Prior thread: $($node.context.prior_thread_id)
Prior handoff: $($node.context.prior_handoff)
Prior handoff SHA-256: $($node.context.prior_handoff_hash)
Reuse reason: $($node.context.reuse_reason)
Maximum inherited turns: $($node.context.max_prior_turns)
"@
} else {
    'Start from a fresh execution session. Use only the explicit context below.'
}
$handoffText = if ($node.context.handoff_required) {
@"
Handoff: at most $($node.context.handoff_max_chars) characters to
$($node.context.handoff_path), containing decisions, evidence, risks,
risk_disposition, and exact next_action.
"@
} else {
    'Handoff: none. Return the compact result directly; do not create a handoff artifact.'
}

$packet = if ($isDeltaRetry) {
@"
# Delta repair contract

Identity: $($role.identity_statement)
Run/node/role: $($plan.run_id) / $($node.id) / $($role.display_name)
Original output: $RetryOutputRef
Failure evidence: $FailureEvidence
Repair only: $RepairInstruction

Do not repeat the original analysis, reload unrelated context, or expand scope.
Return the corrected artifact or smallest patch plus typed evidence for:
$(Join-Bullets @($node.acceptance))
"@
} elseif (-not $Full) {
@"
# Worker contract

Identity: $($role.identity_statement)
Run/node/role: $($plan.run_id) / $($node.id) / $($role.display_name)
Task: $($node.task)
Mission: $($role.mission)
Dependencies: $dependencies

You are a worker, never the orchestrator. Do not create or delegate to agents.

## Context

Session: $($node.context.session_policy)
$priorContext
Read only these references:
$contextReferences

Exclude:
$excludedContext

Do not restate inputs or narrate routine tool use. On failure, return only the
prior-output pointer, failure evidence, and exact repair instruction.

## Output contract

Deliver:
$(Join-Bullets @($role.deliverables))

Acceptance:
$(Join-Bullets @($node.acceptance))

Evidence:
$(Join-Bullets @($role.evidence_rules))

Return: conclusion; evidence/changes; validation; unresolved risks; questions.

## Authority

Role policy: $($role.tool_policy)
Read-only: $($node.read_only)
Write scope:
$scopeText

Non-goals:
$(Join-Bullets @($role.non_goals))

Ask only when:
$(Join-Bullets @($role.question_policy.ask_when))
Maximum questions: $($role.question_policy.max_questions)

Escalate when:
$(Join-Bullets @($role.escalation_conditions))

$handoffText
"@
} else {
@"
# Worker identity

$($role.identity_statement)

You are the **$($role.display_name)** for run $($plan.run_id).
You are a worker, not the orchestrator. You must not create threads, subagents,
workflow nodes, or delegate any part of this task.

## Mission and task

Mission: $($role.mission)

Task: $($node.task)

Node ID: $($node.id)
Dependencies: $dependencies
Workflow: $($node.workflow)
Capability class: $($node.capability)
Effort class: $($node.effort)

## Context efficiency

Read only the explicit references needed for the acceptance checks. Do not
restate supplied context, narrate routine tool use, or produce speculative
alternatives outside the deliverables. Return the smallest evidence-backed
handoff that lets the controller continue without repeating completed work.

## Execution context

Session policy: $($node.context.session_policy)
Continuity key: $($node.context.continuity_key)
$priorContext

Explicit context inputs:
$contextInputs

Exclude from context:
$excludedContext

Do not pull unrelated project conversations into this task. Persistent role
identity does not authorize reusing an overloaded execution thread.

## Responsibilities

$(Join-Bullets @($role.responsibilities))

## Non-goals

$(Join-Bullets @($role.non_goals))

## Required inputs

$(Join-Bullets @($role.required_inputs))

If a required input is unavailable, follow the question and escalation policy;
do not guess.

## Deliverables

$(Join-Bullets @($role.deliverables))

Return these sections: conclusion, evidence or changes, validation, unresolved
risks, and questions.

## Evidence rules

$(Join-Bullets @($role.evidence_rules))

Acceptance checks:
$(Join-Bullets @($node.acceptance))

## Tool and write policy

Role policy: $($role.tool_policy)
Node read-only: $($node.read_only)
Allowed write scope:
$scopeText

All paths outside the allowed scope are forbidden. External, destructive,
account, payment, permission, and production actions are forbidden.

## Question policy

Ask only when:
$(Join-Bullets @($role.question_policy.ask_when))

Maximum questions: $($role.question_policy.max_questions)

Safe assumptions:
$(if (@($role.question_policy.safe_assumptions).Count) {
    Join-Bullets @($role.question_policy.safe_assumptions)
} else { '- None declared.' })

## Escalate to the controller when

$(Join-Bullets @($role.escalation_conditions))

## Handoff

$handoffText
"@
}

if ($OutputPath) {
    $parent = Split-Path -Parent $OutputPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        throw "Output directory does not exist: $parent"
    }
    $root = (Resolve-Path -LiteralPath $WorkspaceRoot).Path.TrimEnd('\', '/')
    $resolvedParent = if ($parent) {
        (Resolve-Path -LiteralPath $parent).Path
    } else {
        (Get-Location).Path
    }
    $candidate = [IO.Path]::GetFullPath((Join-Path $resolvedParent (
        Split-Path -Leaf $OutputPath
    )))
    if (-not $candidate.StartsWith(
        $root + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'OutputPath must stay inside WorkspaceRoot.'
    }
    $relative = [IO.Path]::GetRelativePath($root, $candidate)
    $cursor = $root
    foreach ($segment in ($relative -split '[\\/]')) {
        if ($segment -match '[\. ]$' -or $segment.Contains(':')) {
            throw 'OutputPath contains an unsafe Windows path segment.'
        }
        $cursor = Join-Path $cursor $segment
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'OutputPath crosses a link or reparse point.'
            }
        }
    }
    $packet | Set-Content -LiteralPath $OutputPath
}
$packet
