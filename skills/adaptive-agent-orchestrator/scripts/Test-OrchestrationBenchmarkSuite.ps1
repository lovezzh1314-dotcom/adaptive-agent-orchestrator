[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $BaselinePath,

    [Parameter(Mandatory)]
    [string] $CandidatePath,

    [ValidateRange(3, 1000)]
    [int] $MinimumCases = 3,

    [ValidateRange(0.2, 0.8)]
    [double] $MinimumMedianSavingsRatio = 0.2,

    [ValidateRange(0.1, 1.0)]
    [double] $MaximumP90TokenRatio = 1.0,

    [ValidateRange(0, 2)]
    [double] $MaximumAverageQualityLoss = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-Rows {
    param([string] $Path, [string] $Name)
    $resolvedMetricsPath = (Resolve-Path -LiteralPath $Path).Path
    $rows = @(
        Get-Content -LiteralPath $resolvedMetricsPath -Raw |
            ConvertFrom-Json -Depth 30
    )
    foreach ($row in $rows) {
        foreach ($field in @(
            'case_id', 'comparison_manifest_path', 'comparison_fingerprint',
            'input_tokens', 'output_tokens', 'quality_score'
        )) {
            if ($null -eq $row.PSObject.Properties[$field]) {
                throw "$Name row requires $field."
            }
        }
        if ([string]$row.comparison_fingerprint -notmatch '^[0-9a-f]{64}$') {
            throw "$Name.comparison_fingerprint must be a SHA-256 hex digest."
        }
        $manifestPath = [string]$row.comparison_manifest_path
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
        if ($manifestHash -ne [string]$row.comparison_fingerprint) {
            throw "$Name.comparison_fingerprint does not match its manifest file."
        }
        foreach ($field in @('input_tokens', 'output_tokens', 'quality_score')) {
            if ([double]$row.$field -lt 0) {
                throw "$Name.$field cannot be negative."
            }
        }
    }
    return $rows
}

function Get-Median {
    param([double[]] $Values)
    $sorted = @($Values | Sort-Object)
    $middle = [Math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2) { return [double]$sorted[$middle] }
    return ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2
}

function Get-NearestRank {
    param([double[]] $Values, [double] $Percentile)
    $sorted = @($Values | Sort-Object)
    $index = [Math]::Max(
        0,
        [Math]::Ceiling($Percentile * $sorted.Count) - 1
    )
    return [double]$sorted[$index]
}

$baselineRows = @(Read-Rows $BaselinePath 'baseline')
$candidateRows = @(Read-Rows $CandidatePath 'candidate')
if ($baselineRows.Count -lt $MinimumCases -or
    $candidateRows.Count -ne $baselineRows.Count) {
    throw "Benchmark suite requires matching arrays with at least $MinimumCases cases."
}

$candidateByCase = @{}
foreach ($row in $candidateRows) {
    $id = [string]$row.case_id
    if ($candidateByCase.ContainsKey($id)) {
        throw "Duplicate candidate case_id '$id'."
    }
    $candidateByCase[$id] = $row
}
$baselineCaseIds = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($row in $baselineRows) {
    $id = [string]$row.case_id
    if (-not $baselineCaseIds.Add($id)) {
        throw "Duplicate baseline case_id '$id'."
    }
}

$ratios = [Collections.Generic.List[double]]::new()
$savings = [Collections.Generic.List[double]]::new()
$qualityDeltas = [Collections.Generic.List[double]]::new()
$caseRows = foreach ($baseline in $baselineRows) {
    $id = [string]$baseline.case_id
    if (-not $candidateByCase.ContainsKey($id)) {
        throw "Candidate metrics are missing case_id '$id'."
    }
    $candidate = $candidateByCase[$id]
    if ([string]$baseline.comparison_fingerprint -ne
        [string]$candidate.comparison_fingerprint) {
        throw "Comparison fingerprint mismatch for case_id '$id'."
    }
    $baselineTotal = [double]$baseline.input_tokens +
        [double]$baseline.output_tokens
    $candidateTotal = [double]$candidate.input_tokens +
        [double]$candidate.output_tokens
    if ($baselineTotal -le 0) {
        throw "Baseline case '$id' must have positive total Tokens."
    }
    $ratio = $candidateTotal / $baselineTotal
    $saving = 1 - $ratio
    $qualityDelta = [double]$candidate.quality_score -
        [double]$baseline.quality_score
    $ratios.Add($ratio)
    $savings.Add($saving)
    $qualityDeltas.Add($qualityDelta)
    [pscustomobject]@{
        case_id = $id
        token_ratio = [Math]::Round($ratio, 4)
        savings_ratio = [Math]::Round($saving, 4)
        quality_delta = [Math]::Round($qualityDelta, 2)
    }
}

$medianSavings = Get-Median $savings.ToArray()
$p90Ratio = Get-NearestRank $ratios.ToArray() 0.9
$averageQualityDelta = (
    $qualityDeltas | Measure-Object -Average
).Average
$failures = [Collections.Generic.List[string]]::new()
if ($medianSavings -lt $MinimumMedianSavingsRatio) {
    $failures.Add(
        "Median Token savings $([Math]::Round($medianSavings, 4)) is below $MinimumMedianSavingsRatio."
    )
}
if ($p90Ratio -gt $MaximumP90TokenRatio) {
    $failures.Add(
        "P90 Token ratio $([Math]::Round($p90Ratio, 4)) exceeds $MaximumP90TokenRatio."
    )
}
if ($averageQualityDelta -lt -$MaximumAverageQualityLoss) {
    $failures.Add(
        "Average quality delta $([Math]::Round($averageQualityDelta, 2)) is below -$MaximumAverageQualityLoss."
    )
}

$result = [ordered]@{
    passed = $failures.Count -eq 0
    cases = $baselineRows.Count
    median_token_savings_ratio = [Math]::Round($medianSavings, 4)
    p90_token_ratio = [Math]::Round($p90Ratio, 4)
    average_quality_delta = [Math]::Round($averageQualityDelta, 2)
    case_results = @($caseRows)
    failures = @($failures)
}
if ($failures.Count -gt 0) {
    throw (($result | ConvertTo-Json -Depth 20) + [Environment]::NewLine +
        'Benchmark suite gate failed.')
}
$result | ConvertTo-Json -Depth 20
