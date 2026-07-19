[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RunDirectory,
    [Parameter(Mandatory)][string] $ThreadId,
    [Parameter(Mandatory)][string] $HostId,
    [Parameter(Mandatory)][string] $ThreadReadPath,
    [Parameter(Mandatory)][string] $OutputPath,
    [string[]] $AdoptedFindings = @(),
    [string[]] $RejectedFindings = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')

foreach ($value in @($ThreadId, $HostId)) {
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw 'Thread and host IDs must be non-empty.'
    }
}
if (-not (Test-Path -LiteralPath $RunDirectory -PathType Container)) {
    throw "Run directory does not exist: $RunDirectory"
}
if (-not (Test-Path -LiteralPath $ThreadReadPath -PathType Leaf)) {
    throw "Thread-read capture does not exist: $ThreadReadPath"
}
if (Test-Path -LiteralPath $OutputPath) {
    throw "Thread result receipt already exists: $OutputPath"
}
if ([IO.Path]::GetFileName($OutputPath) -notlike '*.thread-result-receipt.json') {
    throw 'OutputPath must end with .thread-result-receipt.json.'
}
$runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
$captureFullPath = [IO.Path]::GetFullPath($ThreadReadPath)
$outputFullPath = [IO.Path]::GetFullPath($OutputPath)
foreach ($candidate in @($captureFullPath, $outputFullPath)) {
    if (-not $candidate.StartsWith(
        $runRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Thread-read capture and receipt must remain inside the run.'
    }
}
$captureRelativePath = $captureFullPath.Substring($runRoot.Length + 1)
$captureSegments = $captureRelativePath -split '[\\/]'
if (@($captureSegments | Where-Object {
    $_ -in @('', '.', '..') -or $_ -match '[\. ]$' -or $_.Contains(':')
}).Count -gt 0) {
    throw 'Thread-read capture path contains an unsafe segment.'
}
$final = Read-ThreadReadCapture -Path $captureFullPath `
    -ExpectedThreadId $ThreadId
$adopted = @($AdoptedFindings | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_)
})
$rejected = @($RejectedFindings | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_)
})
if ($adopted.Count + $rejected.Count -eq 0) {
    throw 'At least one adopted or rejected finding is required.'
}
$receipt = [ordered]@{
    schema_version = '1.1'
    thread_id = $ThreadId
    host_id = $HostId
    collection_method = 'read_thread'
    thread_read_path = $captureRelativePath.Replace('\', '/')
    thread_read_hash = $final.capture_hash
    final_turn_id = $final.final_turn_id
    final_status = 'completed'
    final_content_hash = $final.final_content_hash
    adopted_findings = $adopted
    rejected_findings = $rejected
}
$receipt.receipt_hash = Get-TextSha256 (
    $receipt | ConvertTo-Json -Compress -Depth 20
)
$parent = Split-Path -Parent $outputFullPath
if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    $null = New-Item -ItemType Directory -Path $parent
}
$receipt | ConvertTo-Json -Depth 20 |
    Set-Content -LiteralPath $outputFullPath
$receipt | ConvertTo-Json -Depth 20
