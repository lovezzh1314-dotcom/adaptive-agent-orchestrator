[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RunDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$planPath = Join-Path $RunDirectory 'plan.json'
$runPath = Join-Path $RunDirectory 'run.json'
if (-not (Test-Path -LiteralPath $planPath) -or
    -not (Test-Path -LiteralPath $runPath)) {
    throw "Run directory is incomplete: $RunDirectory"
}

$plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json -Depth 100
$run = Get-Content -LiteralPath $runPath -Raw | ConvertFrom-Json -Depth 20
$state = & (Join-Path $scriptRoot 'Get-OrchestrationState.ps1') `
    -RunDirectory $RunDirectory | ConvertFrom-Json -Depth 100
$root = (Resolve-Path -LiteralPath $run.workspace_root).Path.TrimEnd('\', '/')
$errors = [Collections.Generic.List[string]]::new()
$successStates = @('validated', 'adopted', 'archived')

foreach ($nodeId in @($plan.completion.required_nodes)) {
    $nodeState = @($state.nodes | Where-Object { $_.id -eq $nodeId }) |
        Select-Object -First 1
    if ($null -eq $nodeState -or $nodeState.status -notin $successStates) {
        $errors.Add("Required node '$nodeId' is not validated.")
    }
}

foreach ($check in @($plan.completion.artifact_checks)) {
    $segments = $check.path -split '[\\/]'
    if (@($segments | Where-Object {
        $_ -in @('', '.', '..') -or $_ -match '[\. ]$' -or $_.Contains(':')
    }).Count -gt 0) {
        $errors.Add("Artifact check contains an unsafe path segment: '$($check.path)'.")
        continue
    }
    $candidate = [IO.Path]::GetFullPath((Join-Path $root $check.path))
    if (-not $candidate.StartsWith(
        $root + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        $errors.Add("Artifact check escapes workspace root: '$($check.path)'.")
        continue
    }
    $cursor = $root
    $unsafeAncestor = $false
    foreach ($segment in $segments) {
        $cursor = Join-Path $cursor $segment
        if (Test-Path -LiteralPath $cursor) {
            $ancestor = Get-Item -LiteralPath $cursor -Force
            if (($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                $errors.Add("Artifact path crosses a link or reparse point: '$($check.path)'.")
                $unsafeAncestor = $true
                break
            }
        }
    }
    if ($unsafeAncestor) { continue }
    if (-not (Test-Path -LiteralPath $candidate)) {
        $errors.Add("Required artifact is missing: '$($check.path)'.")
        continue
    }
    $item = Get-Item -LiteralPath $candidate -Force
    if ($check.type -eq 'file' -and -not $item.PSIsContainer) {
        if ($null -ne $check.PSObject.Properties['minimum_bytes'] -and
            $item.Length -lt [int64]$check.minimum_bytes) {
            $errors.Add("Artifact '$($check.path)' is smaller than minimum_bytes.")
        }
    } elseif ($check.type -eq 'file') {
        $errors.Add("Artifact '$($check.path)' must be a file.")
    }
    if ($check.type -eq 'directory' -and -not $item.PSIsContainer) {
        $errors.Add("Artifact '$($check.path)' must be a directory.")
    } elseif ($check.type -eq 'directory' -and
        $null -ne $check.PSObject.Properties['minimum_items']) {
        $count = @(Get-ChildItem -LiteralPath $candidate -Force).Count
        if ($count -lt [int]$check.minimum_items) {
            $errors.Add("Artifact '$($check.path)' has fewer than minimum_items.")
        }
    }
}

foreach ($check in @($plan.completion.evidence_checks)) {
    $nodeState = @($state.nodes | Where-Object { $_.id -eq $check.node_id }) |
        Select-Object -First 1
    $count = if ($null -eq $nodeState) { 0 } else { @($nodeState.evidence).Count }
    if ($count -lt [int]$check.minimum_entries) {
        $errors.Add("Node '$($check.node_id)' lacks required evidence entries.")
    }
}

if ($errors.Count) {
    throw ($errors -join [Environment]::NewLine)
}

[pscustomobject]@{
    complete = $true
    run_id = $plan.run_id
    required_nodes = @($plan.completion.required_nodes).Count
    artifact_checks = @($plan.completion.artifact_checks).Count
    evidence_checks = @($plan.completion.evidence_checks).Count
    journal_head = $state.journal_head
} | ConvertTo-Json -Depth 10
