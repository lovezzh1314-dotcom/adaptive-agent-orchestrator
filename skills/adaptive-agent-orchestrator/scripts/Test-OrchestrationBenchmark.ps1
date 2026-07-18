[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $BaselinePath,

    [Parameter(Mandatory)]
    [string] $CandidatePath,

    [ValidateRange(0.2, 0.8)]
    [double] $MinimumTokenSavingsRatio = 0.2,

    [ValidateRange(0, 2)]
    [double] $MaximumQualityLoss = 2,

    [ValidateRange(0, 0.2)]
    [double] $MaximumCoordinationRatio = 0.2,

    [ValidateRange(0, 0.1)]
    [double] $MaximumRepetitionRatio = 0.1,

    [ValidateRange(0, 1.25)]
    [double] $MaximumLatencyRatio = 1.25
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-Metrics {
    param([string] $Path, [string] $Name)
    $resolvedMetricsPath = (Resolve-Path -LiteralPath $Path).Path
    $metrics = Get-Content -LiteralPath $resolvedMetricsPath -Raw |
        ConvertFrom-Json -Depth 20
    foreach ($field in @(
        'case_id', 'comparison_manifest_path', 'comparison_fingerprint',
        'variant', 'input_tokens', 'output_tokens', 'useful_output_tokens',
        'coordination_tokens', 'repeated_tokens', 'recovery_tokens',
        'wall_clock_seconds', 'quality_score'
    )) {
        if ($null -eq $metrics.PSObject.Properties[$field]) {
            throw "$Name metrics require $field."
        }
    }
    foreach ($field in @(
        'input_tokens', 'output_tokens', 'useful_output_tokens',
        'coordination_tokens', 'repeated_tokens', 'recovery_tokens',
        'wall_clock_seconds', 'quality_score'
    )) {
        $value = [double]$metrics.$field
        if ($value -lt 0) { throw "$Name.$field cannot be negative." }
    }
    if ([string]$metrics.comparison_fingerprint -notmatch '^[0-9a-f]{64}$') {
        throw "$Name.comparison_fingerprint must be a SHA-256 hex digest."
    }
    $manifestPath = [string]$metrics.comparison_manifest_path
    if (-not [IO.Path]::IsPathRooted($manifestPath)) {
        $manifestPath = Join-Path (
            Split-Path -Parent $resolvedMetricsPath
        ) $manifestPath
    }
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "$Name.comparison_manifest_path does not exist."
    }
    $manifestHash = (
        Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    if ($manifestHash -ne [string]$metrics.comparison_fingerprint) {
        throw "$Name.comparison_fingerprint does not match its manifest file."
    }
    if ([double]$metrics.quality_score -gt 100) {
        throw "$Name.quality_score cannot exceed 100."
    }
    $metrics | Add-Member -NotePropertyName total_tokens -NotePropertyValue (
        [double]$metrics.input_tokens +
        [double]$metrics.output_tokens
    )
    if ([double]$metrics.repeated_tokens -gt [double]$metrics.input_tokens) {
        throw "$Name.repeated_tokens cannot exceed input_tokens."
    }
    if ([double]$metrics.useful_output_tokens -gt [double]$metrics.output_tokens) {
        throw "$Name.useful_output_tokens cannot exceed output_tokens."
    }
    if ([double]$metrics.coordination_tokens -gt [double]$metrics.total_tokens) {
        throw "$Name.coordination_tokens cannot exceed total_tokens."
    }
    if ([double]$metrics.recovery_tokens -gt [double]$metrics.total_tokens) {
        throw "$Name.recovery_tokens cannot exceed total_tokens."
    }
    return $metrics
}

$baseline = Read-Metrics $BaselinePath 'baseline'
$candidate = Read-Metrics $CandidatePath 'candidate'
if ([string]$baseline.case_id -ne [string]$candidate.case_id) {
    throw 'Benchmark case_id values must match.'
}
if ([string]$baseline.comparison_fingerprint -ne
    [string]$candidate.comparison_fingerprint) {
    throw 'Benchmark comparison_fingerprint values must match.'
}
if ($baseline.total_tokens -le 0 -or [double]$baseline.wall_clock_seconds -le 0) {
    throw 'Baseline total_tokens and wall_clock_seconds must be positive.'
}

$tokenRatio = $candidate.total_tokens / $baseline.total_tokens
$savingsRatio = 1 - $tokenRatio
$qualityDelta = [double]$candidate.quality_score - [double]$baseline.quality_score
$coordinationRatio = if ($candidate.total_tokens) {
    [double]$candidate.coordination_tokens / $candidate.total_tokens
} else { 0 }
$repetitionRatio = if ([double]$candidate.input_tokens) {
    [double]$candidate.repeated_tokens / [double]$candidate.input_tokens
} else { 0 }
$latencyRatio = [double]$candidate.wall_clock_seconds /
    [double]$baseline.wall_clock_seconds
$usefulTokenRatio = if ($candidate.total_tokens) {
    [double]$candidate.useful_output_tokens / $candidate.total_tokens
} else { 0 }

$failures = [System.Collections.Generic.List[string]]::new()
if ($savingsRatio -lt $MinimumTokenSavingsRatio) {
    $failures.Add("Token savings $([Math]::Round($savingsRatio, 4)) is below $MinimumTokenSavingsRatio.")
}
if ($qualityDelta -lt -$MaximumQualityLoss) {
    $failures.Add("Quality delta $qualityDelta is below -$MaximumQualityLoss.")
}
if ($coordinationRatio -gt $MaximumCoordinationRatio) {
    $failures.Add("Coordination ratio $([Math]::Round($coordinationRatio, 4)) exceeds $MaximumCoordinationRatio.")
}
if ($repetitionRatio -gt $MaximumRepetitionRatio) {
    $failures.Add("Repetition ratio $([Math]::Round($repetitionRatio, 4)) exceeds $MaximumRepetitionRatio.")
}
if ($latencyRatio -gt $MaximumLatencyRatio) {
    $failures.Add("Latency ratio $([Math]::Round($latencyRatio, 4)) exceeds $MaximumLatencyRatio.")
}

$result = [ordered]@{
    passed = $failures.Count -eq 0
    case_id = $baseline.case_id
    baseline_variant = $baseline.variant
    candidate_variant = $candidate.variant
    token_savings_ratio = [Math]::Round($savingsRatio, 4)
    token_ratio = [Math]::Round($tokenRatio, 4)
    quality_delta = [Math]::Round($qualityDelta, 2)
    coordination_ratio = [Math]::Round($coordinationRatio, 4)
    repetition_ratio = [Math]::Round($repetitionRatio, 4)
    latency_ratio = [Math]::Round($latencyRatio, 4)
    useful_token_ratio = [Math]::Round($usefulTokenRatio, 4)
    recovery_tokens = [int64]$candidate.recovery_tokens
    failures = @($failures)
}

if ($failures.Count -gt 0) {
    throw (($result | ConvertTo-Json -Depth 10) + [Environment]::NewLine +
        'Benchmark gate failed.')
}

$result | ConvertTo-Json -Depth 10
