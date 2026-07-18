[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $PlanPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Value {
    param([object] $Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-OverlapRatio {
    param([object[]] $Left, [object[]] $Right)
    $leftSet = @($Left | ForEach-Object {
        ([string]$_).Trim().ToLowerInvariant()
    } | Where-Object { $_ } | Select-Object -Unique)
    $rightSet = @($Right | ForEach-Object {
        ([string]$_).Trim().ToLowerInvariant()
    } | Where-Object { $_ } | Select-Object -Unique)
    $union = @($leftSet + $rightSet | Select-Object -Unique)
    if ($union.Count -eq 0) { return 1.0 }
    $intersection = @($leftSet | Where-Object { $_ -in $rightSet })
    return [double]$intersection.Count / $union.Count
}

$plan = Get-Content -LiteralPath (Resolve-Path -LiteralPath $PlanPath) -Raw |
    ConvertFrom-Json -Depth 100
$policy = Get-Value $plan 'efficiency'
if ($null -eq $policy) { throw 'Plan requires efficiency.' }

if ([string]$policy.profile -notin @('lean', 'balanced', 'quality')) {
    throw 'efficiency.profile must be lean, balanced, or quality.'
}
if ([string]$policy.context_strategy -ne 'reference-first') {
    throw 'efficiency.context_strategy must be reference-first.'
}
if ([string]$policy.dispatch_strategy -ne 'progressive') {
    throw 'efficiency.dispatch_strategy must be progressive.'
}
if ([string]$policy.retry_strategy -ne 'delta') {
    throw 'efficiency.retry_strategy must be delta.'
}
if ([string]$policy.review_strategy -notin @('risk-only', 'sampled', 'always')) {
    throw 'efficiency.review_strategy must be risk-only, sampled, or always.'
}
$maxOverlap = Get-Value $policy 'max_context_overlap_ratio'
if ($null -eq $maxOverlap -or $maxOverlap -isnot [ValueType] -or
    [double]$maxOverlap -lt 0 -or [double]$maxOverlap -gt 1) {
    throw 'efficiency.max_context_overlap_ratio must be 0..1.'
}
if ([string]$policy.fallback -ne 'main-only') {
    throw 'efficiency.fallback must be main-only.'
}
if ([string]$policy.profile -eq 'lean' -and [double]$maxOverlap -gt 0.5) {
    throw 'Lean profile max_context_overlap_ratio cannot exceed 0.5.'
}

$agentNodes = @($plan.nodes | Where-Object { $_.kind -eq 'agent' })
$errors = [Collections.Generic.List[string]]::new()
foreach ($node in $agentNodes) {
    $wave = Get-Value $node 'wave'
    if ($null -eq $wave -or [int]$wave -lt 1 -or [int]$wave -gt 100) {
        $errors.Add("Agent node '$($node.id)' requires wave 1..100.")
    }
    $inputRefs = @($node.context.inputs | ForEach-Object {
        ([string]$_).Trim()
    } | Where-Object { $_ })
    if ($inputRefs.Count -eq 0) {
        $errors.Add("Agent node '$($node.id)' requires explicit context inputs.")
    } elseif (@($inputRefs | Where-Object {
        $_ -notmatch '^(ref|path|source|artifact):\S'
    }).Count -gt 0) {
        $errors.Add(
            "Agent node '$($node.id)' context inputs must be typed references."
        )
    } elseif (@($inputRefs | Select-Object -Unique).Count -ne $inputRefs.Count) {
        $errors.Add("Agent node '$($node.id)' repeats a context reference.")
    }
    $broadRefs = @($inputRefs | Where-Object {
        $_ -match '^(path:(\.|\.?[\\/]|[*]{1,2})|(?:ref|source|artifact):(all|everything|entire[-_ ]?(repo|repository|project|conversation)))$'
    })
    if ($broadRefs.Count -gt 0) {
        $errors.Add(
            "Agent node '$($node.id)' uses broad context reference '$($broadRefs[0])'."
        )
    }
}
if (@($agentNodes | Where-Object { [int]$_.wave -eq 1 }).Count -gt 1) {
    $errors.Add('Wave 1 may contain only one worker; dispatch progressively.')
}
foreach ($node in $agentNodes | Where-Object { [int]$_.wave -gt 1 }) {
    $earlierAgents = @($agentNodes | Where-Object {
        [int]$_.wave -lt [int]$node.wave
    })
    $earlierAgentIds = @($earlierAgents | ForEach-Object { $_.id })
    if (@($node.depends_on | Where-Object { $_ -in $earlierAgentIds }).Count -eq 0) {
        $overlapsEarlierContext = @($earlierAgents | Where-Object {
            (Get-OverlapRatio @($_.context.inputs) @($node.context.inputs)) -gt 0
        }).Count -gt 0
        if ($overlapsEarlierContext) {
            $errors.Add(
                "Later-wave node '$($node.id)' must depend on an earlier adopted result or own disjoint context."
            )
        }
    }
}

$maximumObservedOverlap = 0.0
for ($leftIndex = 0; $leftIndex -lt $agentNodes.Count; $leftIndex++) {
    for ($rightIndex = $leftIndex + 1; $rightIndex -lt $agentNodes.Count; $rightIndex++) {
        $left = $agentNodes[$leftIndex]
        $right = $agentNodes[$rightIndex]
        $overlap = Get-OverlapRatio @($left.context.inputs) @($right.context.inputs)
        $maximumObservedOverlap = [Math]::Max($maximumObservedOverlap, $overlap)
        if ($overlap -gt [double]$maxOverlap) {
            $errors.Add(
                "Context overlap $([Math]::Round($overlap, 4)) between '$($left.id)' and '$($right.id)' exceeds $maxOverlap."
            )
        }
    }
}
if ([string]$policy.profile -eq 'lean' -and @($agentNodes | Where-Object {
    $_.workflow -eq 'race'
}).Count -gt 0) {
    $errors.Add('Lean profile forbids speculative race nodes.')
}
if ([string]$policy.profile -eq 'lean' -and @($agentNodes | Where-Object {
    $_.capability -eq 'ultra' -or $_.effort -eq 'ultra'
}).Count -gt 0) {
    $errors.Add('Lean profile forbids Ultra nodes.')
}
if ([string]$policy.profile -eq 'lean' -and [string]$plan.risk -eq 'low' -and
    @($agentNodes | Where-Object { $_.purpose -eq 'verification' }).Count -gt 0) {
    $errors.Add('Lean low-risk plans must skip a dedicated verification worker.')
}
if ([string]$policy.review_strategy -eq 'risk-only' -and
    [string]$plan.risk -eq 'low' -and
    @($agentNodes | Where-Object { $_.purpose -eq 'verification' }).Count -gt 0) {
    $errors.Add('Risk-only review may not create a reviewer for a low-risk task.')
}

$result = [ordered]@{
    valid = $errors.Count -eq 0
    decision = if ($errors.Count -eq 0) { 'orchestrate' } else { 'main-only' }
    profile = $policy.profile
    worker_count = $agentNodes.Count
    waves = @($agentNodes | ForEach-Object { [int]$_.wave } |
        Sort-Object -Unique)
    maximum_context_overlap_ratio =
        [Math]::Round($maximumObservedOverlap, 4)
    receipt = "$($agentNodes.Count) workers · reference-first context · progressive dispatch · delta retry · $($policy.review_strategy) review"
    errors = @($errors)
}

if ($errors.Count -gt 0) {
    throw (($result | ConvertTo-Json -Depth 20) + [Environment]::NewLine +
        'Context-efficiency gate rejected orchestration.')
}

$result | ConvertTo-Json -Depth 20
