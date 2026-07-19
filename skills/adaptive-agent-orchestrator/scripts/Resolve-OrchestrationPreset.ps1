[CmdletBinding()]
param(
    [ValidateSet('auto', 'quick', 'team', 'workflow')]
    [string] $Mode = 'auto',

    [ValidateSet('low', 'medium', 'high')]
    [string] $Risk = 'low',

    [ValidateRange(0, 6)]
    [int] $IndependentWorkstreams = 0,

    [ValidateRange(1, 64)]
    [int] $RuntimeWorkerCapacity = 6,

    [switch] $NeedsRecovery,
    [switch] $HasStageDependencies,
    [switch] $HasMultipleWriters,
    [switch] $HasApprovalGate,
    [switch] $QualityPriority
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$durableReasons = [Collections.Generic.List[string]]::new()
if ($NeedsRecovery) { $durableReasons.Add('recovery') }
if ($HasStageDependencies) { $durableReasons.Add('stage-dependencies') }
if ($HasMultipleWriters) { $durableReasons.Add('multiple-writers') }
if ($HasApprovalGate) { $durableReasons.Add('approval-gate') }

$resolvedMode = $Mode
if ($Mode -eq 'auto') {
    if ($durableReasons.Count -gt 0) {
        $resolvedMode = 'workflow'
    } elseif ($IndependentWorkstreams -ge 2) {
        $resolvedMode = 'team'
    } else {
        $resolvedMode = 'quick'
    }
}

if ($resolvedMode -eq 'quick' -and (
    $durableReasons.Count -gt 0 -or $IndependentWorkstreams -gt 1
)) {
    throw 'quick conflicts with durable requirements or multiple independent workstreams.'
}
if ($resolvedMode -eq 'team' -and $IndependentWorkstreams -lt 2) {
    throw 'team requires at least two independent workstreams.'
}
if ($resolvedMode -eq 'team' -and $durableReasons.Count -gt 0) {
    throw 'team conflicts with durable requirements; use workflow.'
}
if ($resolvedMode -eq 'workflow' -and $durableReasons.Count -eq 0) {
    throw 'workflow requires recovery, stage dependencies, multiple writers, or an approval gate.'
}

$profile = if ($QualityPriority -or $Risk -eq 'high') {
    'quality'
} elseif ($Risk -eq 'medium' -or $resolvedMode -in @('team', 'workflow')) {
    'balanced'
} else {
    'lean'
}
$reviewStrategy = switch ($profile) {
    'lean' { 'risk-only' }
    'balanced' { 'sampled' }
    'quality' { 'always' }
}

$effectiveActive = [Math]::Min(6, $RuntimeWorkerCapacity)
$transientReserve = [Math]::Min(2, $effectiveActive)
$persistentLimit = [Math]::Min(4, [Math]::Max(0, $effectiveActive - $transientReserve))

[ordered]@{
    requested_mode = $Mode
    mode = $resolvedMode
    profile = $profile
    review_strategy = $reviewStrategy
    durable_reasons = @($durableReasons)
    limits = [ordered]@{
        max_concurrent_nodes = $effectiveActive
        persistent_active_limit = $persistentLimit
        transient_reserved_slots = $transientReserve
        max_total_agent_nodes = 8
        max_new_nodes_per_wave = 2
    }
} | ConvertTo-Json -Depth 10
