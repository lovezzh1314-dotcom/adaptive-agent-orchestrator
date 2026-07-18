[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $PlanPath,
    [Parameter(Mandatory)][string] $NodeId,
    [Parameter(Mandatory)][string] $WorkspaceRoot,
    [string] $OutputPath
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

$packet = @"
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

Before the controller closes or rotates this execution session, return a
compact handoff no longer than $($node.context.handoff_max_chars) characters.
It must contain conclusions, decisions, evidence pointers, artifacts,
an explicit risk disposition (`none`, `open`, or `mitigated`), unresolved
risks, and the exact next action. The controller stores it at:
$($node.context.handoff_path)
"@

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
