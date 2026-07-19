Set-StrictMode -Version Latest

function Get-TextSha256 {
    param([Parameter(Mandatory)][string] $Text)
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($Text)
        )
    ).ToLowerInvariant()
}

function Get-JournalMutexName {
    param([Parameter(Mandatory)][string] $EventsPath)
    $resolved = (Resolve-Path -LiteralPath $EventsPath).Path
    return 'AdaptiveAgentOrchestrator-' + (Get-TextSha256 $resolved).Substring(0, 24)
}

function Get-OrchestrationEventHash {
    param([Parameter(Mandatory)][object] $Event)
    $keys = @(
        'sequence', 'prev_hash', 'timestamp', 'event', 'run_id', 'plan_hash',
        'workspace_root',
        'policy_version', 'actor', 'node_id', 'role_id', 'prior_state', 'status',
        'message', 'thread_id', 'model_id', 'artifact', 'topology', 'capability',
        'effort', 'wave', 'attempt', 'execution_slot_delta', 'error_class',
        'input_tokens_delta', 'output_tokens_delta',
        'coordination_tokens_delta', 'usage_source',
        'decision', 'human_actor', 'evidence', 'idempotency_key',
        'request_fingerprint'
    )
    $payload = [ordered]@{}
    foreach ($key in $keys) {
        $property = $Event.PSObject.Properties[$key]
        $value = if ($null -eq $property) { $null } else { $property.Value }
        $payload[$key] = $value
    }
    return Get-TextSha256 ($payload | ConvertTo-Json -Compress -Depth 10)
}

function Read-OrchestrationJournal {
    param([Parameter(Mandatory)][string] $EventsPath)
    $events = @(
        Get-Content -LiteralPath $EventsPath |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_ | ConvertFrom-Json -Depth 30 -DateKind String }
    )
    $previousHash = $null
    for ($index = 0; $index -lt $events.Count; $index++) {
        $event = $events[$index]
        if ([int]$event.sequence -ne $index) {
            throw "Journal sequence gap at index $index."
        }
        if ([string]$event.prev_hash -ne [string]$previousHash) {
            throw "Journal hash-chain break at sequence $index."
        }
        $expectedHash = Get-OrchestrationEventHash $event
        if ([string]$event.hash -ne $expectedHash) {
            throw "Journal event hash mismatch at sequence $index."
        }
        $previousHash = $event.hash
    }
    return $events
}

function Read-ThreadReadCapture {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $ExpectedThreadId
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Thread-read capture does not exist: $Path"
    }
    $raw = Get-Content -LiteralPath $Path -Raw
    $capture = $raw | ConvertFrom-Json -Depth 100 -DateKind String
    if ($null -eq $capture.PSObject.Properties['page'] -or
        [string]$capture.page.order -ne 'newest_first') {
        throw 'Thread-read capture must declare newest_first turn order.'
    }
    $captureThreadId = if (
        $null -ne $capture.PSObject.Properties['thread'] -and
        $null -ne $capture.thread.PSObject.Properties['threadId']
    ) {
        [string]$capture.thread.threadId
    } elseif ($null -ne $capture.PSObject.Properties['threadId']) {
        [string]$capture.threadId
    } else { '' }
    if ($captureThreadId -ne $ExpectedThreadId) {
        throw 'Thread-read capture does not match the expected thread.'
    }
    $turns = @($capture.turns)
    if ($turns.Count -eq 0) {
        throw 'Thread-read capture has no turns.'
    }
    $finalTurn = $turns[0]
    if ([string]$finalTurn.status -ne 'completed') {
        throw 'Newest thread turn is not completed.'
    }
    $finalMessages = @($finalTurn.items | Where-Object {
        [string]$_.type -eq 'agentMessage' -and
        [string]$_.phase -eq 'final_answer' -and
        -not [string]::IsNullOrWhiteSpace([string]$_.text)
    })
    if ($finalMessages.Count -eq 0 -or
        [string]::IsNullOrWhiteSpace([string]$finalTurn.id)) {
        throw 'Completed thread turn lacks a final agent answer.'
    }
    $finalText = [string]$finalMessages[-1].text
    return [pscustomobject]@{
        final_turn_id = [string]$finalTurn.id
        final_content_hash = Get-TextSha256 $finalText
        capture_hash = Get-TextSha256 $raw
    }
}

function Read-ThreadResultReceipt {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $ExpectedThreadId,
        [Parameter(Mandatory)][string] $RunDirectory
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Thread result receipt does not exist: $Path"
    }
    $receipt = Get-Content -LiteralPath $Path -Raw |
        ConvertFrom-Json -Depth 30 -DateKind String
    $required = @(
        'schema_version', 'thread_id', 'host_id', 'collection_method',
        'thread_read_path', 'thread_read_hash', 'final_turn_id',
        'final_status', 'final_content_hash',
        'adopted_findings', 'rejected_findings', 'receipt_hash'
    )
    foreach ($name in $required) {
        if ($null -eq $receipt.PSObject.Properties[$name]) {
            throw "Thread result receipt is missing '$name'."
        }
    }
    if ([string]$receipt.thread_id -ne $ExpectedThreadId) {
        throw 'Thread result receipt does not match the materialized thread.'
    }
    if ([string]$receipt.final_status -ne 'completed' -or
        [string]$receipt.collection_method -ne 'read_thread') {
        throw 'Thread result receipt is not a completed supported collection.'
    }
    if ([string]$receipt.final_content_hash -notmatch '^[0-9a-f]{64}$' -or
        [string]$receipt.thread_read_hash -notmatch '^[0-9a-f]{64}$' -or
        [string]::IsNullOrWhiteSpace([string]$receipt.host_id) -or
        [string]::IsNullOrWhiteSpace([string]$receipt.final_turn_id)) {
        throw 'Thread result receipt contains invalid identifiers or hash.'
    }
    if (@($receipt.adopted_findings).Count +
        @($receipt.rejected_findings).Count -eq 0) {
        throw 'Thread result receipt lacks an adoption disposition.'
    }
    $relativeCapture = [string]$receipt.thread_read_path
    $segments = $relativeCapture -split '[\\/]'
    if (@($segments | Where-Object {
        $_ -in @('', '.', '..') -or $_ -match '[\. ]$' -or $_.Contains(':')
    }).Count -gt 0) {
        throw 'Thread result receipt has an unsafe capture path.'
    }
    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $capturePath = [IO.Path]::GetFullPath(
        (Join-Path $runRoot $relativeCapture)
    )
    if (-not $capturePath.StartsWith(
        $runRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Thread result capture escapes the run.'
    }
    $final = Read-ThreadReadCapture -Path $capturePath `
        -ExpectedThreadId $ExpectedThreadId
    if ($final.capture_hash -ne [string]$receipt.thread_read_hash -or
        $final.final_turn_id -ne [string]$receipt.final_turn_id -or
        $final.final_content_hash -ne [string]$receipt.final_content_hash) {
        throw 'Thread result receipt does not match its read-thread capture.'
    }
    $payload = [ordered]@{
        schema_version = [string]$receipt.schema_version
        thread_id = [string]$receipt.thread_id
        host_id = [string]$receipt.host_id
        collection_method = [string]$receipt.collection_method
        thread_read_path = [string]$receipt.thread_read_path
        thread_read_hash = [string]$receipt.thread_read_hash
        final_turn_id = [string]$receipt.final_turn_id
        final_status = [string]$receipt.final_status
        final_content_hash = [string]$receipt.final_content_hash
        adopted_findings = @($receipt.adopted_findings)
        rejected_findings = @($receipt.rejected_findings)
    }
    $expectedHash = Get-TextSha256 (
        $payload | ConvertTo-Json -Compress -Depth 20
    )
    if ([string]$receipt.receipt_hash -ne $expectedHash) {
        throw 'Thread result receipt hash mismatch.'
    }
    return $receipt
}

function Read-ThreadReconciliationReceipt {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $RunDirectory,
        [string] $ExpectedDecision
    )

    $runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd('\', '/')
    $receiptPath = [IO.Path]::GetFullPath($Path)
    if (-not $receiptPath.StartsWith(
        $runRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    ) -or -not (Test-Path -LiteralPath $receiptPath -PathType Leaf) -or
        [IO.Path]::GetFileName($receiptPath) -notlike
            '*.thread-reconciliation.json') {
        throw 'Thread reconciliation receipt must be an existing run-local receipt.'
    }
    $receipt = Get-Content -LiteralPath $receiptPath -Raw |
        ConvertFrom-Json -Depth 30 -DateKind String
    $inputRelativePath = [string]$receipt.reconciliation_input_path
    $inputSegments = $inputRelativePath -split '[\\/]'
    if (@($inputSegments | Where-Object {
        $_ -in @('', '.', '..') -or $_ -match '[\. ]$' -or $_.Contains(':')
    }).Count -gt 0) {
        throw 'Thread reconciliation receipt has an unsafe input path.'
    }
    $inputPath = [IO.Path]::GetFullPath(
        (Join-Path $runRoot $inputRelativePath)
    )
    if (-not $inputPath.StartsWith(
        $runRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    ) -or -not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
        throw 'Thread reconciliation input is missing.'
    }
    $inputRaw = Get-Content -LiteralPath $inputPath -Raw
    if ((Get-TextSha256 $inputRaw) -ne
        [string]$receipt.reconciliation_input_hash) {
        throw 'Thread reconciliation input hash mismatch.'
    }
    $input = $inputRaw | ConvertFrom-Json -Depth 50 -DateKind String
    $reservationPath = [IO.Path]::GetFullPath(
        [string]$input.reservation_path
    )
    $activationRoot = [IO.Path]::GetFullPath(
        (Join-Path $runRoot 'receipts\activations')
    ).TrimEnd('\', '/')
    if (-not $reservationPath.StartsWith(
        $activationRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    ) -or -not (Test-Path -LiteralPath $reservationPath -PathType Leaf)) {
        throw 'Thread reconciliation activation reservation is missing.'
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
    $reservationHash = Get-TextSha256 (
        $reservationPayload | ConvertTo-Json -Compress -Depth 10
    )
    if ([string]$reservation.reservation_hash -ne $reservationHash -or
        [string]$receipt.activation_reservation_hash -ne $reservationHash) {
        throw 'Thread reconciliation activation reservation hash mismatch.'
    }
    $payload = [ordered]@{
        schema_version = [string]$receipt.schema_version
        reconciliation_input_path = $inputRelativePath
        reconciliation_input_hash = [string]$receipt.reconciliation_input_hash
        activation_key = [string]$receipt.activation_key
        activation_reservation_hash = [string]$receipt.activation_reservation_hash
        source_thread_id = [string]$receipt.source_thread_id
        task_summary_hash = [string]$receipt.task_summary_hash
        window_start_utc = [string]$receipt.window_start_utc
        window_end_utc = [string]$receipt.window_end_utc
        create_call_status = [string]$receipt.create_call_status
        returned_thread_id = $receipt.returned_thread_id
        snapshot_count = [int]$receipt.snapshot_count
        visibility_delay_seconds = [double]$receipt.visibility_delay_seconds
        snapshot_captured_at = @($receipt.snapshot_captured_at)
        matched_thread_ids = @($receipt.matched_thread_ids)
        decision = [string]$receipt.decision
        adopted_thread_id = $receipt.adopted_thread_id
        adopted_host_id = $receipt.adopted_host_id
        duplicate_thread_ids = @($receipt.duplicate_thread_ids)
    }
    $expectedHash = Get-TextSha256 (
        $payload | ConvertTo-Json -Compress -Depth 20
    )
    if ([string]$receipt.receipt_hash -ne $expectedHash) {
        throw 'Thread reconciliation receipt hash mismatch.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedDecision) -and
        [string]$receipt.decision -ne $ExpectedDecision) {
        throw "Thread reconciliation decision is not '$ExpectedDecision'."
    }
    $normalizedSummary = [regex]::Replace(
        ([string]$input.task_summary).Trim(),
        '\s+',
        ' '
    ).ToLowerInvariant()
    if ([string]$receipt.activation_key -ne [string]$input.activation_key -or
        [string]$receipt.source_thread_id -ne [string]$input.source_thread_id -or
        [string]$receipt.task_summary_hash -ne
            (Get-TextSha256 $normalizedSummary) -or
        [string]$reservation.activation_key -ne [string]$input.activation_key -or
        [string]$reservation.source_thread_id -ne [string]$input.source_thread_id -or
        [string]$reservation.task_summary_hash -ne
            (Get-TextSha256 $normalizedSummary)) {
        throw 'Thread reconciliation receipt is not bound to its input.'
    }
    if ([string]$receipt.decision -eq 'no_match') {
        $snapshotTimes = @($input.snapshots | ForEach-Object {
            [DateTimeOffset]::Parse(
                [string]$_.captured_at,
                [Globalization.CultureInfo]::InvariantCulture
            ).ToUniversalTime()
        })
        $windowEnd = [DateTimeOffset]::Parse(
            [string]$input.window_end_utc,
            [Globalization.CultureInfo]::InvariantCulture
        ).ToUniversalTime()
        $hasMatchingThread = $false
        foreach ($snapshot in @($input.snapshots)) {
            foreach ($thread in @($snapshot.threads)) {
                $preview = if ($null -ne
                    $thread.PSObject.Properties['preview']) {
                    [string]$thread.preview
                } else { '' }
                $activation = if ($null -ne
                    $thread.PSObject.Properties['activation_key']) {
                    [string]$thread.activation_key
                } else {
                    $match = [regex]::Match(
                        $preview,
                        '<activation_key>([^<]+)</activation_key>'
                    )
                    if ($match.Success) {
                        [string]$match.Groups[1].Value
                    } else { '' }
                }
                $source = if ($null -ne
                    $thread.PSObject.Properties['source_thread_id']) {
                    [string]$thread.source_thread_id
                } else {
                    $match = [regex]::Match(
                        $preview,
                        '<source_thread_id>([^<]+)</source_thread_id>'
                    )
                    if ($match.Success) {
                        [string]$match.Groups[1].Value
                    } else { '' }
                }
                if ($activation -eq [string]$input.activation_key -and
                    $source -eq [string]$input.source_thread_id) {
                    $hasMatchingThread = $true
                }
            }
        }
        if ($snapshotTimes.Count -lt 2 -or
            ($snapshotTimes[-1] - $snapshotTimes[0]).TotalSeconds -lt 5 -or
            $snapshotTimes[-1] -lt $windowEnd -or
            $hasMatchingThread) {
            throw 'Thread reconciliation no-match is not supported by its input.'
        }
    }
    return $receipt
}
