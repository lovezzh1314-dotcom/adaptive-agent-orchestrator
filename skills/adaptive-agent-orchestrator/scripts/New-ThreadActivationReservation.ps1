[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RunDirectory,
    [Parameter(Mandatory)][string] $ActivationKey,
    [Parameter(Mandatory)][string] $SourceThreadId,
    [Parameter(Mandatory)][string] $TaskSummary,
    [Parameter(Mandatory)][string] $RolePreviewPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')

foreach ($value in @($ActivationKey, $SourceThreadId, $TaskSummary)) {
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw 'Activation key, source thread, and task summary must be non-empty.'
    }
}
if (-not (Test-Path -LiteralPath $RunDirectory -PathType Container)) {
    throw "Run directory does not exist: $RunDirectory"
}
$runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
$resolvedPreviewPath = [IO.Path]::GetFullPath($RolePreviewPath)
if (-not $resolvedPreviewPath.StartsWith(
    $runRoot + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase
) -or -not (Test-Path -LiteralPath $resolvedPreviewPath -PathType Leaf)) {
    throw 'Role preview must be an existing file inside the run directory.'
}
$previewText = Get-Content -LiteralPath $resolvedPreviewPath -Raw
if ([string]::IsNullOrWhiteSpace($previewText) -or
    $previewText -notlike '*Execution form:*' -or
    $previewText -notlike '*Why this execution form:*' -or
    $previewText -notlike '*Why a Worker is needed:*') {
    throw 'Role preview is incomplete.'
}
$relativePreviewPath = [IO.Path]::GetRelativePath(
    $runRoot,
    $resolvedPreviewPath
).Replace('\', '/')
$normalizedSummary = (
    [regex]::Replace($TaskSummary.Trim(), '\s+', ' ')
).ToLowerInvariant()
$keyHash = Get-TextSha256 $ActivationKey.Trim()
$reservationDirectory = Join-Path $RunDirectory 'receipts\activations'
if (-not (Test-Path -LiteralPath $reservationDirectory)) {
    $null = New-Item -ItemType Directory -Path $reservationDirectory -Force
}
$reservationPath = Join-Path $reservationDirectory (
    "$keyHash.thread-activation.json"
)
$reservation = [ordered]@{
    schema_version = '1.0'
    activation_key = $ActivationKey.Trim()
    activation_key_hash = $keyHash
    source_thread_id = $SourceThreadId.Trim()
    task_summary_hash = Get-TextSha256 $normalizedSummary
    role_preview_path = $relativePreviewPath
    role_preview_hash = Get-TextSha256 $previewText
    reserved_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
}
$reservation.reservation_hash = Get-TextSha256 (
    $reservation | ConvertTo-Json -Compress -Depth 10
)
$json = $reservation | ConvertTo-Json -Depth 10
$bytes = [Text.Encoding]::UTF8.GetBytes($json)
try {
    $stream = [IO.File]::Open(
        $reservationPath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    try {
        $stream.Write($bytes, 0, $bytes.Length)
    } finally {
        $stream.Dispose()
    }
} catch [IO.IOException] {
    throw (
        'Activation key is already reserved. Reconcile the existing ' +
        "reservation instead of creating another thread: $reservationPath"
    )
}
[pscustomobject]@{
    reservation_path = $reservationPath
    activation_key = $reservation.activation_key
    activation_key_hash = $reservation.activation_key_hash
    reservation_hash = $reservation.reservation_hash
} | ConvertTo-Json -Depth 10
