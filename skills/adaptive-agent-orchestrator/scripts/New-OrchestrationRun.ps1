[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $PlanPath,

    [Parameter(Mandatory)]
    [string] $RunDirectory,

    [Parameter(Mandatory)]
    [string] $WorkspaceRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Orchestration.Common.ps1')

$resolvedWorkspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
& (Join-Path $scriptRoot 'Test-OrchestrationPlan.ps1') `
    -PlanPath $PlanPath -WorkspaceRoot $resolvedWorkspace | Out-Null
if (Test-Path -LiteralPath $RunDirectory) {
    throw "RunDirectory already exists: $RunDirectory"
}

$null = New-Item -ItemType Directory -Path $RunDirectory
$planDestination = Join-Path $RunDirectory 'plan.json'
Copy-Item -LiteralPath $PlanPath -Destination $planDestination
$planText = Get-Content -LiteralPath $planDestination -Raw
$planHash = Get-TextSha256 $planText
$runMetadata = [ordered]@{
    run_id = $null
    policy_version = $null
    plan_hash = $planHash
    workspace_root = $resolvedWorkspace
}
$eventsPath = Join-Path $RunDirectory 'events.jsonl'
$null = New-Item -ItemType File -Path $eventsPath

$plan = $planText | ConvertFrom-Json -Depth 100
$runMetadata.run_id = $plan.run_id
$runMetadata.policy_version = $plan.policy_version
$runMetadata | ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath (Join-Path $RunDirectory 'run.json')
$created = [ordered]@{
    sequence = 0
    prev_hash = $null
    timestamp = [DateTimeOffset]::UtcNow.ToString('o')
    event = 'run-created'
    run_id = $plan.run_id
    plan_hash = $planHash
    workspace_root = $resolvedWorkspace
    policy_version = $plan.policy_version
    actor = $plan.orchestrator.id
    node_id = $null
    role_id = $null
    prior_state = $null
    status = 'planned'
    message = 'Validated orchestration run created.'
    thread_id = $null
    artifact = $null
    topology = $null
    capability = $null
    effort = $null
    wave = 0
    attempt = 0
    execution_slot_delta = 0
    input_tokens_delta = 0
    output_tokens_delta = 0
    coordination_tokens_delta = 0
    usage_source = 'none'
    error_class = $null
    evidence = @()
    idempotency_key = "$($plan.run_id):run-created"
    request_fingerprint = $null
}
$created.hash = Get-OrchestrationEventHash ([pscustomobject]$created)
Add-Content -LiteralPath $eventsPath -Value ($created | ConvertTo-Json -Compress)

& (Join-Path $scriptRoot 'Get-OrchestrationState.ps1') -RunDirectory $RunDirectory
