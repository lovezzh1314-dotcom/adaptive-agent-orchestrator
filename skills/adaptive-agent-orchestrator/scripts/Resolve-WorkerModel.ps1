[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('economy', 'standard', 'strong', 'ultra')]
    [string] $Capability,

    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max', 'ultra')]
    [string] $Effort,

    [string] $RequestedModel,
    [string] $PriorRunDirectory,
    [string] $PriorNodeId,
    [string] $WorkspaceRoot,

    [string[]] $AvailableModelIds,
    [string] $ModelsCachePath,

    [switch] $AllowExperimentalTerra,
    [switch] $UserConfirmedEscalation,
    [switch] $UserConfirmedUltra,

    [string] $AuthorizationEvidence
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$defaultModel = if ($Capability -eq 'economy') {
    'gpt-5.6-luna'
} else {
    'gpt-5.6-sol'
}
$defaultEffort = switch ($Capability) {
    'economy' { 'medium' }
    'standard' { 'medium' }
    'strong' { 'high' }
    'ultra' { 'ultra' }
}
$model = if ($RequestedModel) { $RequestedModel } else { $defaultModel }
$resolvedEffort = if ($Effort) { $Effort } else { $defaultEffort }
$priorModel = $null
$priorEffort = $null

if ($PriorRunDirectory -or $PriorNodeId) {
    if (-not $PriorRunDirectory -or -not $PriorNodeId) {
        throw 'PriorRunDirectory and PriorNodeId must be provided together.'
    }
    $commonScript = Join-Path $PSScriptRoot 'Orchestration.Common.ps1'
    . $commonScript
    $priorPlanPath = Join-Path $PriorRunDirectory 'plan.json'
    $priorEventsPath = Join-Path $PriorRunDirectory 'events.jsonl'
    $priorRunPath = Join-Path $PriorRunDirectory 'run.json'
    if (-not (Test-Path -LiteralPath $priorPlanPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $priorEventsPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $priorRunPath -PathType Leaf)) {
        throw 'Prior run is missing plan.json, run.json, or events.jsonl.'
    }
    $null = & (Join-Path $PSScriptRoot 'Get-OrchestrationState.ps1') `
        -RunDirectory $PriorRunDirectory
    $priorPlan = Get-Content -LiteralPath $priorPlanPath -Raw |
        ConvertFrom-Json -Depth 100
    $priorNode = @($priorPlan.nodes | Where-Object {
        $_.id -eq $PriorNodeId -and $_.kind -eq 'agent'
    }) | Select-Object -First 1
    if (-not $priorNode) {
        throw "Prior agent node '$PriorNodeId' was not found."
    }
    $priorEvents = @(Read-OrchestrationJournal $priorEventsPath)
    $priorHistory = @($priorEvents | Where-Object {
        $_.node_id -eq $PriorNodeId
    })
    if (-not $priorHistory.Count -or $priorHistory[-1].status -ne 'failed') {
        throw "Prior agent node '$PriorNodeId' must be in failed state."
    }
    $priorMaterialization = @($priorHistory | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.model_id)
    }) | Select-Object -Last 1
    if (-not $priorMaterialization) {
        throw "Prior agent node '$PriorNodeId' has no recorded actual model."
    }
    $priorModel = [string]$priorMaterialization.model_id
    $priorEffort = [string]$priorNode.effort
}

$allowedModels = @('gpt-5.6-luna', 'gpt-5.6-sol', 'gpt-5.6-terra')
if ($model -notin $allowedModels) {
    throw "Model '$model' is outside the supported GPT-5.6 worker pool."
}
if ($model -eq 'gpt-5.6-terra' -and -not (
    $RequestedModel -and $AllowExperimentalTerra -and
    $AuthorizationEvidence -match '^user:.+'
)) {
    throw 'Terra requires an explicit request, AllowExperimentalTerra, and user: authorization evidence.'
}
if ($AuthorizationEvidence -match '^policy:path:(.+)$') {
    $policyPath = $Matches[1]
    $policySegments = @($policyPath -split '[\\/]')
    if (-not $WorkspaceRoot -or [IO.Path]::IsPathRooted($policyPath) -or
        $policySegments -contains '..' -or
        @($policySegments | Where-Object {
            $_ -match '[\. ]$' -or $_.Contains(':')
        }).Count -gt 0) {
        throw 'policy:path authorization must reference an existing safe project-relative file.'
    }
    $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path.TrimEnd(
        '\', '/'
    )
    $resolvedPolicyPath = [IO.Path]::GetFullPath(
        (Join-Path $resolvedRoot $policyPath)
    )
    if (-not $resolvedPolicyPath.StartsWith(
        $resolvedRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    ) -or -not (Test-Path -LiteralPath $resolvedPolicyPath -PathType Leaf)) {
        throw 'policy:path authorization must reference an existing safe project-relative file.'
    }
    $cursor = $resolvedRoot
    foreach ($segment in $policySegments) {
        if ($segment -in @('', '.')) { continue }
        $cursor = Join-Path $cursor $segment
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'policy:path authorization cannot cross a link or reparse point.'
            }
        }
    }
}
if ($Capability -eq 'ultra' -or $resolvedEffort -eq 'ultra') {
    if ($model -ne 'gpt-5.6-sol' -or $Capability -ne 'ultra' -or
        $resolvedEffort -ne 'ultra' -or -not $UserConfirmedUltra -or
        $AuthorizationEvidence -notmatch '^user:.+') {
        throw 'Ultra requires Sol, capability ultra, effort ultra, and user: confirmation evidence.'
    }
}

$supportedEfforts = $null
if (-not $AvailableModelIds) {
    if (-not $ModelsCachePath) {
        $ModelsCachePath = Join-Path $env:USERPROFILE '.codex\models_cache.json'
    }
    if (-not (Test-Path -LiteralPath $ModelsCachePath -PathType Leaf)) {
        throw "Model cache not found: $ModelsCachePath"
    }
    $cache = Get-Content -LiteralPath $ModelsCachePath -Raw |
        ConvertFrom-Json -Depth 20
    $AvailableModelIds = @($cache.models | ForEach-Object { [string]$_.slug })
    $selectedMetadata = @($cache.models | Where-Object {
        [string]$_.slug -eq $model
    }) | Select-Object -First 1
    if ($selectedMetadata) {
        $supportedEfforts = @(
            $selectedMetadata.supported_reasoning_levels |
                ForEach-Object { [string]$_.effort }
        )
    }
}
if ($model -notin $AvailableModelIds) {
    throw "Selected model '$model' is unavailable in the current runtime."
}
if ($supportedEfforts -and $resolvedEffort -notin $supportedEfforts) {
    throw "Model '$model' does not support effort '$resolvedEffort'."
}

$effortOrder = @('low', 'medium', 'high', 'xhigh', 'max', 'ultra')
$isDefaultModelEscalation = $Capability -eq 'economy' -and
    $model -eq 'gpt-5.6-sol'
$isModelEscalation = $priorModel -in @('gpt-5.6-luna', 'gpt-5.6-terra') -and
    $model -eq 'gpt-5.6-sol'
$isEffortEscalation = $priorEffort -and
    $effortOrder.IndexOf($resolvedEffort) -gt $effortOrder.IndexOf($priorEffort)
if (($isDefaultModelEscalation -or $isModelEscalation -or
    $isEffortEscalation) -and
    -not $UserConfirmedEscalation -and -not $UserConfirmedUltra) {
    throw 'Model or effort escalation requires explicit user confirmation.'
}
if (($UserConfirmedEscalation -or $UserConfirmedUltra) -and
    $AuthorizationEvidence -notmatch '^(user:.+|policy:path:.+)') {
    throw 'Confirmed model changes require user: or policy:path: authorization evidence.'
}

[ordered]@{
    capability = $Capability
    model = $model
    effort = $resolvedEffort
    prior_model = $priorModel
    prior_effort = $priorEffort
    experimental = $model -eq 'gpt-5.6-terra'
    authorization = if ($UserConfirmedUltra) {
        'ultra-confirmed'
    } elseif ($UserConfirmedEscalation) {
        'escalation-confirmed'
    } elseif ($model -eq 'gpt-5.6-terra') {
        'experimental-user-request'
    } else {
        'not-required'
    }
    authorization_evidence = if ($AuthorizationEvidence) {
        $AuthorizationEvidence
    } else { $null }
    reason = switch ($Capability) {
        'economy' { 'bounded mechanical work' }
        'standard' { 'ordinary judgment, drafting, implementation, or testing' }
        'strong' { 'high ambiguity, architecture, difficult debugging, or critical review' }
        'ultra' { 'user-confirmed exceptional adjudication' }
    }
} | ConvertTo-Json -Depth 5
