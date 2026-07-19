[CmdletBinding()]
param(
    [ValidateRange(1, 64)]
    [int] $RuntimeWorkerCapacity = 6,

    [ValidateRange(0, 64)]
    [int] $ActivePersistentWorkers = 0,

    [ValidateRange(0, 64)]
    [int] $ActiveTransientWorkers = 0,

    [ValidateSet('none', 'persistent', 'transient')]
    [string] $RequestedKind = 'none',

    [switch] $BorrowTransientReserve,
    [switch] $UserConfirmedBorrow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$effectiveCapacity = [Math]::Min(6, $RuntimeWorkerCapacity)
$reservedTransient = [Math]::Min(2, $effectiveCapacity)
$persistentLimit = [Math]::Min(
    4,
    [Math]::Max(0, $effectiveCapacity - $reservedTransient)
)
$activeTotal = $ActivePersistentWorkers + $ActiveTransientWorkers
if ($activeTotal -gt $effectiveCapacity) {
    throw 'Observed active Worker count exceeds the effective runtime capacity.'
}
if ($BorrowTransientReserve -and -not $UserConfirmedBorrow) {
    throw 'Borrowing a transient reserve requires explicit user confirmation.'
}

$allowed = $true
$reason = 'capacity-available'
if ($RequestedKind -eq 'transient' -and $activeTotal -ge $effectiveCapacity) {
    $allowed = $false
    $reason = 'runtime-capacity-exhausted'
}
if ($RequestedKind -eq 'persistent') {
    if ($activeTotal -ge $effectiveCapacity) {
        $allowed = $false
        $reason = 'runtime-capacity-exhausted'
    } elseif ($ActivePersistentWorkers -ge 4) {
        $allowed = $false
        $reason = 'persistent-active-limit-exhausted'
    } elseif ($ActivePersistentWorkers -ge $persistentLimit -and
        -not ($BorrowTransientReserve -and $UserConfirmedBorrow)) {
        $allowed = $false
        $reason = 'transient-reserve-protected'
    }
}

[ordered]@{
    allowed = $allowed
    reason = $reason
    requested_kind = $RequestedKind
    effective_capacity = $effectiveCapacity
    active_persistent = $ActivePersistentWorkers
    active_transient = $ActiveTransientWorkers
    active_total = $activeTotal
    target_persistent_active_limit = 4
    effective_persistent_active_limit = $persistentLimit
    transient_reserved_slots = $reservedTransient
    remaining_total_slots = $effectiveCapacity - $activeTotal
} | ConvertTo-Json -Depth 5
