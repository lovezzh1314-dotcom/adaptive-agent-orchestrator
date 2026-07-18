[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RunDirectory,
    [Parameter(Mandatory)][string] $NodeId,
    [Parameter(Mandatory)][string] $Summary,
    [string[]] $Decisions = @(),
    [Parameter(Mandatory)][string[]] $Evidence,
    [string[]] $UnresolvedRisks = @(),
    [Parameter(Mandatory)]
    [ValidateSet('none', 'open', 'mitigated')]
    [string] $RiskDisposition,
    [Parameter(Mandatory)][string] $NextAction
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')
$planPath = Join-Path $RunDirectory 'plan.json'
$runPath = Join-Path $RunDirectory 'run.json'
if (-not (Test-Path -LiteralPath $planPath) -or
    -not (Test-Path -LiteralPath $runPath)) {
    throw "Run directory is incomplete: $RunDirectory"
}

$plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json -Depth 100
$run = Get-Content -LiteralPath $runPath -Raw | ConvertFrom-Json -Depth 20
$node = @($plan.nodes | Where-Object { $_.id -eq $NodeId }) |
    Select-Object -First 1
if ($null -eq $node -or $node.kind -ne 'agent') {
    throw "Handoffs require a known agent node: '$NodeId'."
}
if ($node.context.handoff_required -ne $true) {
    throw "Node '$NodeId' does not require a handoff."
}
$state = & (Join-Path $scriptRoot 'Get-OrchestrationState.ps1') `
    -RunDirectory $RunDirectory | ConvertFrom-Json -Depth 100
$nodeState = @($state.nodes | Where-Object { $_.id -eq $NodeId }) |
    Select-Object -First 1
if ($nodeState.status -notin @('validated', 'adopted', 'archived')) {
    throw "Node '$NodeId' must be validated before creating a handoff."
}
$selectedEvidence = @($Evidence | Where-Object {
    -not [string]::IsNullOrWhiteSpace([string]$_)
} | Select-Object -Unique)
if ($selectedEvidence.Count -eq 0) {
    throw "Handoff '$NodeId' requires at least one selected evidence pointer."
}
$unknownEvidence = @($selectedEvidence | Where-Object {
    $_ -notin @($nodeState.evidence)
})
if ($unknownEvidence.Count -gt 0) {
    throw "Handoff evidence '$($unknownEvidence[0])' is not recorded for node '$NodeId'."
}
if ([string]::IsNullOrWhiteSpace($NextAction)) {
    throw "NextAction is required for handoff '$NodeId'."
}
if ($RiskDisposition -eq 'open' -and @($UnresolvedRisks).Count -eq 0) {
    throw "RiskDisposition 'open' requires at least one unresolved risk."
}
if ($RiskDisposition -eq 'none' -and @($UnresolvedRisks).Count -gt 0) {
    throw "RiskDisposition 'none' cannot include unresolved risks."
}

$root = (Resolve-Path -LiteralPath $run.workspace_root).Path.TrimEnd('\', '/')
$relativePath = [string]$node.context.handoff_path
$segments = $relativePath -split '[\\/]'
if ([IO.Path]::IsPathRooted($relativePath) -or
    @($segments | Where-Object {
        $_ -in @('', '.', '..') -or $_ -match '[\. ]$' -or $_.Contains(':')
    }).Count -gt 0) {
    throw "Unsafe handoff path: '$relativePath'."
}
$outputPath = [IO.Path]::GetFullPath((Join-Path $root $relativePath))
if (-not $outputPath.StartsWith(
    $root + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw "Handoff path escapes workspace root: '$relativePath'."
}
$cursor = $root
foreach ($segment in $segments) {
    $cursor = Join-Path $cursor $segment
    if (Test-Path -LiteralPath $cursor) {
        $item = Get-Item -LiteralPath $cursor -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Handoff path crosses a link or reparse point: '$relativePath'."
        }
    }
}
if (Test-Path -LiteralPath $outputPath) {
    throw "Handoff already exists and is immutable: '$relativePath'."
}

$handoff = [ordered]@{
    schema_version = '1.0'
    run_id = $plan.run_id
    plan_hash = $state.plan_hash
    node_id = $node.id
    role_id = $node.role_id
    continuity_key = $node.context.continuity_key
    thread_id = $nodeState.thread_id
    status = $nodeState.status
    summary = $Summary
    decisions = @($Decisions)
    evidence = $selectedEvidence
    artifact = $nodeState.artifact
    risk_disposition = $RiskDisposition
    unresolved_risks = @($UnresolvedRisks)
    next_action = $NextAction
    created_at = [DateTimeOffset]::UtcNow.ToString('o')
}

$parent = Split-Path -Parent $outputPath
if (-not (Test-Path -LiteralPath $parent)) {
    $null = New-Item -ItemType Directory -Path $parent
}
$handoffJson = $handoff | ConvertTo-Json -Depth 20
if ($handoffJson.Length -gt [int]$node.context.handoff_max_chars) {
    throw "Serialized handoff exceeds context.handoff_max_chars for '$NodeId'."
}
$handoffJson | Set-Content -LiteralPath $outputPath
$storedText = Get-Content -LiteralPath $outputPath -Raw
[ordered]@{
    handoff_path = $relativePath
    handoff_sha256 = Get-TextSha256 $storedText
    handoff = $handoff
} | ConvertTo-Json -Depth 20
