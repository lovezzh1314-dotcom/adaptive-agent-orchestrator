[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $InputPath,

    [Parameter(Mandatory)]
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')

function Convert-ToUtc {
    param([Parameter(Mandatory)] $Value)

    if ($Value -is [ValueType] -and $Value -isnot [datetime]) {
        return [DateTimeOffset]::FromUnixTimeSeconds([int64]$Value).ToUniversalTime()
    }
    return [DateTimeOffset]::Parse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture
    ).ToUniversalTime()
}

function Get-NormalizedSummary {
    param([Parameter(Mandatory)][string] $Value)

    return ([regex]::Replace($Value.Trim(), '\s+', ' ')).ToLowerInvariant()
}

if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
    throw "Reconciliation input does not exist: $InputPath"
}
$inputRaw = Get-Content -LiteralPath $InputPath -Raw
$input = $inputRaw |
    ConvertFrom-Json -Depth 50 -DateKind String
foreach ($name in @(
    'activation_key', 'source_thread_id', 'task_summary',
    'window_start_utc', 'window_end_utc', 'reservation_path',
    'create_call', 'snapshots'
)) {
    if ($null -eq $input.PSObject.Properties[$name]) {
        throw "Reconciliation input is missing '$name'."
    }
}
$reservationPath = [string]$input.reservation_path
if (-not (Test-Path -LiteralPath $reservationPath -PathType Leaf)) {
    throw "Activation reservation does not exist: $reservationPath"
}
$reservation = Get-Content -LiteralPath $reservationPath -Raw |
    ConvertFrom-Json -Depth 20 -DateKind String
$reservationPayload = [ordered]@{
    schema_version = [string]$reservation.schema_version
    activation_key = [string]$reservation.activation_key
    activation_key_hash = [string]$reservation.activation_key_hash
    source_thread_id = [string]$reservation.source_thread_id
    task_summary_hash = [string]$reservation.task_summary_hash
    role_preview_path = [string]$reservation.role_preview_path
    role_preview_hash = [string]$reservation.role_preview_hash
    reserved_at_utc = [string]$reservation.reserved_at_utc
}
$expectedReservationHash = Get-TextSha256 (
    $reservationPayload | ConvertTo-Json -Compress -Depth 10
)
if ([string]$reservation.reservation_hash -ne $expectedReservationHash) {
    throw 'Activation reservation hash mismatch.'
}
$reservationFullPath = [IO.Path]::GetFullPath($reservationPath)
$runRoot = Split-Path -Parent (
    Split-Path -Parent (
        Split-Path -Parent $reservationFullPath
    )
)
$inputFullPath = [IO.Path]::GetFullPath($InputPath)
if (-not $inputFullPath.StartsWith(
    [IO.Path]::GetFullPath($runRoot).TrimEnd('\', '/') +
        [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw 'Reconciliation input must remain inside the run.'
}
$relativeInputPath = [IO.Path]::GetRelativePath(
    [IO.Path]::GetFullPath($runRoot),
    $inputFullPath
).Replace('\', '/')
$previewFullPath = [IO.Path]::GetFullPath(
    (Join-Path $runRoot ([string]$reservation.role_preview_path))
)
if (-not $previewFullPath.StartsWith(
    [IO.Path]::GetFullPath($runRoot).TrimEnd('\', '/') +
        [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase
) -or -not (Test-Path -LiteralPath $previewFullPath -PathType Leaf) -or
    (Get-TextSha256 (
        Get-Content -LiteralPath $previewFullPath -Raw
    )) -ne [string]$reservation.role_preview_hash) {
    throw 'Activation reservation role preview is missing or changed.'
}
$outputFullPath = [IO.Path]::GetFullPath($OutputPath)
if (-not $outputFullPath.StartsWith(
    [IO.Path]::GetFullPath($runRoot).TrimEnd('\', '/') +
        [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase
) -or
    [IO.Path]::GetFileName($outputFullPath) -notlike
        '*.thread-reconciliation.json') {
    throw (
        'Reconciliation receipt must remain inside the run and end with ' +
        '.thread-reconciliation.json.'
    )
}
if ([string]::IsNullOrWhiteSpace([string]$input.activation_key) -or
    [string]::IsNullOrWhiteSpace([string]$input.source_thread_id) -or
    [string]::IsNullOrWhiteSpace([string]$input.task_summary)) {
    throw 'Activation key, source thread, and task summary must be non-empty.'
}
$windowStart = Convert-ToUtc $input.window_start_utc
$windowEnd = Convert-ToUtc $input.window_end_utc
if ($windowEnd -lt $windowStart) {
    throw 'Reconciliation window end must not precede its start.'
}
$snapshots = @($input.snapshots)
if ($snapshots.Count -eq 0) {
    throw 'At least one task-list snapshot is required.'
}
if ([string]$input.create_call.status -notin @(
    'success', 'error', 'timeout', 'unknown'
)) {
    throw 'Create-call status must be success, error, timeout, or unknown.'
}
$expectedSummary = Get-NormalizedSummary ([string]$input.task_summary)
$expectedSummaryHash = Get-TextSha256 $expectedSummary
if ([string]$reservation.activation_key -ne [string]$input.activation_key -or
    [string]$reservation.source_thread_id -ne [string]$input.source_thread_id -or
    [string]$reservation.task_summary_hash -ne $expectedSummaryHash) {
    throw 'Reconciliation input does not match its activation reservation.'
}
$candidateMatches = [Collections.Generic.List[object]]::new()
$snapshotTimes = [Collections.Generic.List[DateTimeOffset]]::new()
foreach ($snapshot in $snapshots) {
    if ($null -eq $snapshot.PSObject.Properties['threads'] -or
        $null -eq $snapshot.PSObject.Properties['captured_at']) {
        throw 'Every task-list snapshot requires captured_at and threads.'
    }
    $capturedAt = Convert-ToUtc $snapshot.captured_at
    if ($snapshotTimes.Count -gt 0 -and
        $capturedAt -le $snapshotTimes[$snapshotTimes.Count - 1]) {
        throw 'Task-list snapshots must have strictly increasing capture times.'
    }
    $snapshotTimes.Add($capturedAt)
    foreach ($thread in @($snapshot.threads)) {
        $threadId = if ($null -ne $thread.PSObject.Properties['thread_id']) {
            [string]$thread.thread_id
        } elseif ($null -ne $thread.PSObject.Properties['id']) {
            [string]$thread.id
        } else { '' }
        $hostId = if ($null -ne $thread.PSObject.Properties['host_id']) {
            [string]$thread.host_id
        } else { '' }
        $sourceThreadId = if (
            $null -ne $thread.PSObject.Properties['source_thread_id']
        ) {
            [string]$thread.source_thread_id
        } elseif ($null -ne $thread.PSObject.Properties['preview']) {
            $sourceMatch = [regex]::Match(
                [string]$thread.preview,
                '<source_thread_id>([^<]+)</source_thread_id>'
            )
            if ($sourceMatch.Success) {
                [string]$sourceMatch.Groups[1].Value
            } else { '' }
        } else { '' }
        $activationKey = if (
            $null -ne $thread.PSObject.Properties['activation_key']
        ) {
            [string]$thread.activation_key
        } elseif ($null -ne $thread.PSObject.Properties['preview']) {
            $activationMatch = [regex]::Match(
                [string]$thread.preview,
                '<activation_key>([^<]+)</activation_key>'
            )
            if ($activationMatch.Success) {
                [string]$activationMatch.Groups[1].Value
            } else { '' }
        } else { '' }
        $summaryMatches = $false
        if ($null -ne $thread.PSObject.Properties['task_summary_hash']) {
            $summaryMatches = (
                [string]$thread.task_summary_hash
            ).ToLowerInvariant() -eq $expectedSummaryHash
        } elseif ($null -ne $thread.PSObject.Properties['task_summary']) {
            $summaryMatches = (
                Get-NormalizedSummary ([string]$thread.task_summary)
            ) -eq $expectedSummary
        } elseif ($null -ne $thread.PSObject.Properties['preview']) {
            $summaryMatches = (
                Get-NormalizedSummary ([string]$thread.preview)
            ).Contains($expectedSummary)
        }
        if ([string]::IsNullOrWhiteSpace($threadId) -or
            [string]::IsNullOrWhiteSpace($hostId) -or
            $sourceThreadId -ne [string]$input.source_thread_id -or
            $activationKey -ne [string]$input.activation_key -or
            -not $summaryMatches -or
            $null -eq $thread.PSObject.Properties['created_at']) {
            continue
        }
        $createdAt = Convert-ToUtc $thread.created_at
        if ($createdAt -lt $windowStart -or $createdAt -gt $windowEnd) {
            continue
        }
        $candidateMatches.Add([pscustomobject][ordered]@{
            thread_id = $threadId
            host_id = $hostId
            created_at = $createdAt.ToString('o')
        })
    }
}
$uniqueMatches = @(
    $candidateMatches |
        Sort-Object thread_id -Unique
)
$returnedThreadId = if (
    $null -ne $input.create_call.PSObject.Properties['returned_thread_id']
) {
    [string]$input.create_call.returned_thread_id
} else { '' }
$decision = 'unknown'
$adoptedThread = $null
$duplicateIds = @()
$visibilityDelaySeconds = if ($snapshotTimes.Count -ge 2) {
    (
        $snapshotTimes[$snapshotTimes.Count - 1] - $snapshotTimes[0]
    ).TotalSeconds
} else { 0 }
if ($uniqueMatches.Count -eq 1) {
    $decision = 'adopted'
    $adoptedThread = $uniqueMatches[0]
} elseif ($uniqueMatches.Count -gt 1) {
    $returnedMatch = @(
        $uniqueMatches | Where-Object { $_.thread_id -eq $returnedThreadId }
    )
    if ($returnedMatch.Count -eq 1) {
        $adoptedThread = $returnedMatch[0]
    } else {
        $ordered = @($uniqueMatches | Sort-Object created_at, thread_id)
        if ($ordered[0].created_at -ne $ordered[1].created_at) {
            $adoptedThread = $ordered[0]
        }
    }
    if ($null -ne $adoptedThread) {
        $decision = 'duplicates_pending'
        $duplicateIds = @(
            $uniqueMatches |
                Where-Object { $_.thread_id -ne $adoptedThread.thread_id } |
                Select-Object -ExpandProperty thread_id
        )
    }
} elseif ($snapshots.Count -ge 2 -and
    $visibilityDelaySeconds -ge 5 -and
    $snapshotTimes[$snapshotTimes.Count - 1] -ge $windowEnd) {
    $decision = 'no_match'
}
$receipt = [ordered]@{
    schema_version = '1.0'
    reconciliation_input_path = $relativeInputPath
    reconciliation_input_hash = Get-TextSha256 $inputRaw
    activation_key = [string]$input.activation_key
    activation_reservation_hash = [string]$reservation.reservation_hash
    source_thread_id = [string]$input.source_thread_id
    task_summary_hash = $expectedSummaryHash
    window_start_utc = $windowStart.ToString('o')
    window_end_utc = $windowEnd.ToString('o')
    create_call_status = [string]$input.create_call.status
    returned_thread_id = if ($returnedThreadId) { $returnedThreadId } else { $null }
    snapshot_count = $snapshots.Count
    visibility_delay_seconds = $visibilityDelaySeconds
    snapshot_captured_at = @($snapshotTimes | ForEach-Object {
        $_.ToString('o')
    })
    matched_thread_ids = @($uniqueMatches | Select-Object -ExpandProperty thread_id)
    decision = $decision
    adopted_thread_id = if ($adoptedThread) { $adoptedThread.thread_id } else { $null }
    adopted_host_id = if ($adoptedThread) { $adoptedThread.host_id } else { $null }
    duplicate_thread_ids = $duplicateIds
}
$receipt.receipt_hash = Get-TextSha256 (
    $receipt | ConvertTo-Json -Compress -Depth 20
)
$json = $receipt | ConvertTo-Json -Depth 20
if (Test-Path -LiteralPath $outputFullPath) {
    throw "Reconciliation receipt already exists: $outputFullPath"
}
$parent = Split-Path -Parent $outputFullPath
if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    $null = New-Item -ItemType Directory -Path $parent
}
Set-Content -LiteralPath $outputFullPath -Value $json
$json
