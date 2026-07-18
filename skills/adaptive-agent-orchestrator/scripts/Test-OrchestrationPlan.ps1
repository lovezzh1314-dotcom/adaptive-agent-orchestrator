[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $PlanPath,

    [string] $WorkspaceRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Errors = [System.Collections.Generic.List[string]]::new()

function Add-PlanError {
    param([string] $Message)
    $script:Errors.Add($Message)
}

function Get-PlanProperty {
    param([object] $Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-PlanProperty {
    param([object] $Object, [string] $Name)
    return $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function Require-Text {
    param([object] $Object, [string] $Name, [string] $Context)
    $value = [string](Get-PlanProperty $Object $Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        Add-PlanError "$Context requires non-empty $Name."
    }
    return $value
}

function Get-NormalizedScope {
    param([string] $Scope, [string] $NodeId)
    if ([string]::IsNullOrWhiteSpace($Scope)) {
        Add-PlanError "Writable node '$NodeId' contains an empty write_scope."
        return $null
    }
    if ([IO.Path]::IsPathRooted($Scope)) {
        Add-PlanError "Node '$NodeId' write_scope must be project-relative: '$Scope'."
        return $null
    }
    if ($Scope.IndexOfAny([char[]]'*?[]') -ge 0) {
        Add-PlanError "Node '$NodeId' write_scope cannot contain wildcards: '$Scope'."
        return $null
    }
    $segments = $Scope -split '[\\/]'
    if ($segments -contains '..') {
        Add-PlanError "Node '$NodeId' write_scope cannot traverse with '..': '$Scope'."
        return $null
    }
    foreach ($segment in $segments) {
        if ($segment -match '[\. ]$' -or $segment.Contains(':')) {
            Add-PlanError "Node '$NodeId' write_scope contains a Windows path alias or stream segment: '$Scope'."
            return $null
        }
    }
    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        Add-PlanError "Writable node '$NodeId' requires -WorkspaceRoot for real-path validation."
        return $null
    }
    $root = (Resolve-Path -LiteralPath $WorkspaceRoot).Path.TrimEnd('\', '/')
    $normalized = [IO.Path]::GetFullPath((Join-Path $root $Scope))
    if (-not $normalized.StartsWith(
        $root + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        Add-PlanError "Node '$NodeId' write_scope escapes the project root: '$Scope'."
        return $null
    }
    $cursor = $root
    foreach ($segment in $segments) {
        if ($segment -in @('', '.')) { continue }
        $cursor = Join-Path $cursor $segment
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Add-PlanError "Node '$NodeId' write_scope crosses a link or reparse point: '$Scope'."
                return $null
            }
        }
    }
    return $normalized.TrimEnd('\', '/').ToLowerInvariant()
}

$resolvedPlan = Resolve-Path -LiteralPath $PlanPath
$plan = Get-Content -LiteralPath $resolvedPlan -Raw | ConvertFrom-Json -Depth 100

if ((Get-PlanProperty $plan 'schema_version') -ne '1.0') {
    Add-PlanError "schema_version must be '1.0'."
}
if ((Get-PlanProperty $plan 'policy_version') -ne '0.4.1') {
    Add-PlanError "policy_version must be '0.4.1'."
}
$null = Require-Text $plan 'run_id' 'Plan'
$null = Require-Text $plan 'goal' 'Plan'
if ((Get-PlanProperty $plan 'mode') -notin @('auto', 'quick', 'team', 'workflow')) {
    Add-PlanError 'mode must be auto, quick, team, or workflow.'
}
if ((Get-PlanProperty $plan 'risk') -notin @('low', 'medium', 'high')) {
    Add-PlanError 'risk must be low, medium, or high.'
}

$orchestrator = Get-PlanProperty $plan 'orchestrator'
if ($null -eq $orchestrator) {
    Add-PlanError 'orchestrator is required.'
} else {
    $null = Require-Text $orchestrator 'id' 'orchestrator'
    if ((Get-PlanProperty $orchestrator 'role') -ne 'controller') {
        Add-PlanError "orchestrator.role must be 'controller'."
    }
    if ((Get-PlanProperty $orchestrator 'allow_delegation') -ne $true) {
        Add-PlanError 'orchestrator.allow_delegation must be true.'
    }
}

$limits = Get-PlanProperty $plan 'limits'
$limitRules = [ordered]@{
    max_concurrent_nodes = @(1, 6)
    max_total_agent_nodes = @(1, 8)
    max_new_nodes_per_wave = @(1, 3)
    max_attempts_per_node = @(1, 2)
    retry_reserve = @(0, 2)
    verification_reserve = @(0, 2)
    max_ultra_nodes = @(0, 1)
    max_agent_depth = @(1, 1)
    max_graph_depth = @(1, 12)
    max_dynamic_nodes = @(0, 2)
    max_forks = @(0, 1)
}
foreach ($entry in $limitRules.GetEnumerator()) {
    $value = Get-PlanProperty $limits $entry.Key
    if ($null -eq $value -or $value -isnot [long] -and $value -isnot [int]) {
        Add-PlanError "limits.$($entry.Key) must be an integer."
        continue
    }
    if ([int]$value -lt $entry.Value[0] -or [int]$value -gt $entry.Value[1]) {
        Add-PlanError "limits.$($entry.Key) must be between $($entry.Value[0]) and $($entry.Value[1])."
    }
}

$nodesValue = Get-PlanProperty $plan 'nodes'
$nodes = if ($null -eq $nodesValue) { @() } else { @($nodesValue) }
if ($nodes.Count -eq 0) { Add-PlanError 'Plan requires at least one node.' }
$agentNodes = @($nodes | Where-Object { (Get-PlanProperty $_ 'kind') -eq 'agent' })
$reserved = [int](Get-PlanProperty $limits 'retry_reserve') +
    [int](Get-PlanProperty $limits 'verification_reserve')
if ($agentNodes.Count + $reserved -gt [int](Get-PlanProperty $limits 'max_total_agent_nodes')) {
    Add-PlanError 'Initial agent nodes plus retry and verification reserves exceed max_total_agent_nodes.'
}

$roleItems = @(Get-PlanProperty $plan 'roles')
$roles = @{}
if ($roleItems.Count -eq 0) { Add-PlanError 'Plan requires at least one role contract.' }
foreach ($role in $roleItems) {
    $roleId = Require-Text $role 'id' 'Role'
    if ($roleId -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
        Add-PlanError "Role id '$roleId' must be lowercase hyphen-case."
    }
    if ($roles.ContainsKey($roleId)) {
        Add-PlanError "Duplicate role id: $roleId"
    } else {
        $roles[$roleId] = $role
    }
    foreach ($field in @('display_name', 'mission', 'identity_statement')) {
        $null = Require-Text $role $field "Role '$roleId'"
    }
    foreach ($field in @(
        'responsibilities', 'non_goals', 'required_inputs', 'deliverables',
        'evidence_rules', 'escalation_conditions'
    )) {
        $values = @(Get-PlanProperty $role $field)
        if ($values.Count -eq 0 -or
            @($values | Where-Object {
                [string]::IsNullOrWhiteSpace([string]$_)
            }).Count -gt 0) {
            Add-PlanError "Role '$roleId' requires non-empty $field."
        }
    }
    if ((Get-PlanProperty $role 'tool_policy') -notin @(
        'read-only', 'scoped-write', 'proposal-only'
    )) {
        Add-PlanError "Role '$roleId' has invalid tool_policy."
    }
    $questionPolicy = Get-PlanProperty $role 'question_policy'
    $maxQuestions = Get-PlanProperty $questionPolicy 'max_questions'
    if ($null -eq $maxQuestions -or [int]$maxQuestions -lt 0 -or
        [int]$maxQuestions -gt 3) {
        Add-PlanError "Role '$roleId' question_policy.max_questions must be 0..3."
    }
    if (@(Get-PlanProperty $questionPolicy 'ask_when').Count -eq 0) {
        Add-PlanError "Role '$roleId' requires question_policy.ask_when."
    }
    if (-not (Test-PlanProperty $questionPolicy 'safe_assumptions')) {
        Add-PlanError "Role '$roleId' requires question_policy.safe_assumptions."
    }
    if ((Get-PlanProperty $role 'user_defined') -isnot [bool]) {
        Add-PlanError "Role '$roleId' requires boolean user_defined."
    }
    $lifetime = Get-PlanProperty $role 'lifetime'
    if ($null -ne $lifetime -and
        $lifetime -notin @('task', 'project', 'user-owned')) {
        Add-PlanError "Role '$roleId' lifetime must be task, project, or user-owned."
    }
    if ($lifetime -eq 'user-owned' -and
        (Get-PlanProperty $role 'user_defined') -ne $true) {
        Add-PlanError "Role '$roleId' user-owned lifetime requires user_defined true."
    }
}

$ids = @{}
$normalizedWriterScopes = @{}
$normalizedHandoffPaths = @{}
foreach ($node in $nodes) {
    $id = Require-Text $node 'id' 'Node'
    if ([string]::IsNullOrWhiteSpace($id)) { continue }
    if ($ids.ContainsKey($id)) {
        Add-PlanError "Duplicate node id: $id"
    } else {
        $ids[$id] = $node
    }

    $kind = Get-PlanProperty $node 'kind'
    if ($kind -notin @('agent', 'main', 'human-gate', 'join')) {
        Add-PlanError "Node '$id' has unsupported kind '$kind'."
        continue
    }
    $dependsOn = @(Get-PlanProperty $node 'depends_on')
    if (-not (Test-PlanProperty $node 'depends_on')) {
        Add-PlanError "Node '$id' requires depends_on, even when empty."
    }
    if (@($dependsOn | Select-Object -Unique).Count -ne @($dependsOn).Count) {
        Add-PlanError "Node '$id' contains duplicate dependencies."
    }

    if ($kind -in @('agent', 'main')) {
        $roleId = Require-Text $node 'role_id' "Node '$id'"
        if (-not $roles.ContainsKey($roleId)) {
            Add-PlanError "Node '$id' references missing role '$roleId'."
        }
        $null = Require-Text $node 'task' "Node '$id'"
        $acceptance = @(Get-PlanProperty $node 'acceptance')
        if ($acceptance.Count -eq 0 -or
            @($acceptance | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) {
            Add-PlanError "Node '$id' requires non-empty acceptance checks."
        }
        $workflow = Get-PlanProperty $node 'workflow'
        if ($workflow -notin @('direct', 'parallel', 'pipeline', 'dag', 'loop', 'race')) {
            Add-PlanError "Node '$id' has invalid workflow '$workflow'."
        }
        if ((Get-PlanProperty $node 'allow_delegation') -ne $false) {
            Add-PlanError "Node '$id' must set allow_delegation to false."
        }
        $maxAttempts = Get-PlanProperty $node 'max_attempts'
        if ($null -eq $maxAttempts -or [int]$maxAttempts -lt 1 -or
            [int]$maxAttempts -gt [int](Get-PlanProperty $limits 'max_attempts_per_node')) {
            Add-PlanError "Node '$id' has invalid max_attempts."
        }
        $capability = Get-PlanProperty $node 'capability'
        $effort = Get-PlanProperty $node 'effort'
        if ($capability -notin @('economy', 'standard', 'strong', 'ultra')) {
            Add-PlanError "Node '$id' has invalid capability '$capability'."
        }
        if ($effort -notin @('low', 'medium', 'high', 'xhigh', 'max', 'ultra')) {
            Add-PlanError "Node '$id' has invalid effort '$effort'."
        }
        $readOnly = Get-PlanProperty $node 'read_only'
        if ($readOnly -isnot [bool]) {
            Add-PlanError "Node '$id' requires boolean read_only."
        }
        if ($roles.ContainsKey($roleId)) {
            $roleToolPolicy = Get-PlanProperty $roles[$roleId] 'tool_policy'
            if ($roleToolPolicy -in @('read-only', 'proposal-only') -and
                $readOnly -ne $true) {
                Add-PlanError "Node '$id' cannot write under role '$roleId' tool_policy '$roleToolPolicy'."
            }
        }
        $scopes = @(Get-PlanProperty $node 'write_scope')
        if ($readOnly -eq $true -and $scopes.Count -gt 0) {
            Add-PlanError "Read-only node '$id' cannot have write_scope."
        }
        if ($readOnly -eq $false -and $scopes.Count -eq 0) {
            Add-PlanError "Writable node '$id' requires write_scope."
        }
        if ($kind -eq 'agent') {
            $topology = Get-PlanProperty $node 'topology'
            if ($topology -notin @('native-subagent', 'background-thread')) {
                Add-PlanError "Agent node '$id' has invalid topology '$topology'."
            }
            if ([string]::IsNullOrWhiteSpace([string](Get-PlanProperty $node 'purpose'))) {
                Add-PlanError "Agent node '$id' requires purpose."
            }
            $context = Get-PlanProperty $node 'context'
            $sessionPolicy = Get-PlanProperty $context 'session_policy'
            if ($sessionPolicy -notin @('fresh', 'reuse')) {
                Add-PlanError "Agent node '$id' context.session_policy must be fresh or reuse."
            }
            $continuityKey = Require-Text $context 'continuity_key' "Agent node '$id' context"
            if ($continuityKey -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
                Add-PlanError "Agent node '$id' context.continuity_key must be lowercase hyphen-case."
            }
            foreach ($field in @('inputs', 'excluded')) {
                $values = @(Get-PlanProperty $context $field)
                if ($values.Count -eq 0 -or
                    @($values | Where-Object {
                        [string]::IsNullOrWhiteSpace([string]$_)
                    }).Count -gt 0) {
                    Add-PlanError "Agent node '$id' context.$field requires non-empty entries."
                }
            }
            if ((Test-PlanProperty $context 'selection_reason') -and
                [string]::IsNullOrWhiteSpace(
                    [string](Get-PlanProperty $context 'selection_reason')
                )) {
                Add-PlanError "Agent node '$id' context.selection_reason cannot be empty."
            }
            $handoffRequired = Get-PlanProperty $context 'handoff_required'
            if ($handoffRequired -isnot [bool]) {
                Add-PlanError "Agent node '$id' context.handoff_required must be boolean."
            } elseif ($handoffRequired) {
                $handoffPath = Require-Text $context 'handoff_path' "Agent node '$id' context"
                $normalizedHandoff = Get-NormalizedScope $handoffPath "$id-handoff"
                if ($null -ne $normalizedHandoff) {
                    if ($normalizedHandoffPaths.ContainsKey($normalizedHandoff)) {
                        Add-PlanError "Duplicate handoff_path between '$id' and '$($normalizedHandoffPaths[$normalizedHandoff])'."
                    } else {
                        $normalizedHandoffPaths[$normalizedHandoff] = $id
                    }
                }
                $handoffMaxChars = Get-PlanProperty $context 'handoff_max_chars'
                if ($null -eq $handoffMaxChars -or
                    ($handoffMaxChars -isnot [long] -and $handoffMaxChars -isnot [int]) -or
                    [int]$handoffMaxChars -lt 500 -or [int]$handoffMaxChars -gt 8000) {
                    Add-PlanError "Agent node '$id' context.handoff_max_chars must be 500..8000."
                }
            } elseif ((Test-PlanProperty $context 'handoff_path') -or
                (Test-PlanProperty $context 'handoff_max_chars')) {
                Add-PlanError "Agent node '$id' without handoff_required cannot set handoff_path or handoff_max_chars."
            }
            $rotateOn = @(Get-PlanProperty $context 'rotate_on')
            foreach ($requiredRotation in @(
                'system-error', 'scope-change', 'version-boundary'
            )) {
                if ($requiredRotation -notin $rotateOn) {
                    Add-PlanError "Agent node '$id' context.rotate_on requires '$requiredRotation'."
                }
            }
            $maxPriorTurns = Get-PlanProperty $context 'max_prior_turns'
            if ($sessionPolicy -eq 'fresh') {
                if ($maxPriorTurns -ne 0) {
                    Add-PlanError "Fresh agent node '$id' must set context.max_prior_turns to 0."
                }
                foreach ($reuseOnlyField in @(
                    'prior_thread_id', 'prior_handoff', 'prior_handoff_hash',
                    'reuse_reason'
                )) {
                    if (Test-PlanProperty $context $reuseOnlyField) {
                        Add-PlanError "Fresh agent node '$id' cannot set context.$reuseOnlyField."
                    }
                }
            } else {
                if ($topology -ne 'background-thread') {
                    Add-PlanError "Only background-thread node '$id' may reuse a session."
                }
                if ($null -eq $maxPriorTurns -or
                    ($maxPriorTurns -isnot [long] -and $maxPriorTurns -isnot [int]) -or
                    [int]$maxPriorTurns -lt 1 -or [int]$maxPriorTurns -gt 6) {
                    Add-PlanError "Reuse agent node '$id' context.max_prior_turns must be 1..6."
                }
                $null = Require-Text $context 'prior_thread_id' "Reuse agent node '$id' context"
                $null = Require-Text $context 'prior_handoff' "Reuse agent node '$id' context"
                $priorHandoffHash = Require-Text $context 'prior_handoff_hash' "Reuse agent node '$id' context"
                if ($priorHandoffHash -notmatch '^[0-9a-fA-F]{64}$') {
                    Add-PlanError "Reuse agent node '$id' context.prior_handoff_hash must be a SHA-256 hex digest."
                }
                $null = Require-Text $context 'reuse_reason' "Reuse agent node '$id' context"
            }
        } elseif ((Get-PlanProperty $node 'topology') -ne 'main') {
            Add-PlanError "Main node '$id' must use topology 'main'."
        }
        if ($readOnly -eq $false) {
            $normalizedWriterScopes[$id] = @(
                $scopes | ForEach-Object { Get-NormalizedScope ([string]$_) $id } |
                    Where-Object { $null -ne $_ }
            )
        }
        $usesUltra = $capability -eq 'ultra' -or $effort -eq 'ultra'
        if ($usesUltra) {
            if ($kind -ne 'agent' -or $capability -ne 'ultra' -or $effort -ne 'ultra') {
                Add-PlanError "Ultra node '$id' must be an agent with capability and effort both set to ultra."
            }
            if ($readOnly -ne $true) {
                Add-PlanError "Ultra node '$id' must be read-only."
            }
            if ([string]::IsNullOrWhiteSpace([string](Get-PlanProperty $node 'ultra_reason'))) {
                Add-PlanError "Ultra node '$id' requires ultra_reason."
            }
            $authorization = Get-PlanProperty $node 'ultra_authorization'
            if ($authorization -ne 'user-requested') {
                Add-PlanError "Ultra node '$id' requires user-requested ultra_authorization."
            }
        }
        if ($workflow -eq 'loop') {
            $maxIterations = Get-PlanProperty $node 'max_iterations'
            if ($null -eq $maxIterations -or [int]$maxIterations -lt 1 -or
                [int]$maxIterations -gt 5 -or
                [string]::IsNullOrWhiteSpace([string](Get-PlanProperty $node 'stop_condition'))) {
                Add-PlanError "Loop node '$id' requires max_iterations 1..5 and stop_condition."
            }
        }
        if ($workflow -eq 'race' -and (
            (Get-PlanProperty $node 'cancel_losers') -ne $true -or
            [string]::IsNullOrWhiteSpace([string](Get-PlanProperty $node 'winner_condition'))
        )) {
            Add-PlanError "Race node '$id' requires cancel_losers=true and winner_condition."
        }
    }

    if ($kind -eq 'human-gate') {
        $null = Require-Text $node 'question' "Human gate '$id'"
        $null = Require-Text $node 'default_safe_action' "Human gate '$id'"
        if (@(Get-PlanProperty $node 'choices').Count -lt 2) {
            Add-PlanError "Human gate '$id' requires at least two choices."
        }
        $choices = @(Get-PlanProperty $node 'choices')
        if (@($choices | Select-Object -Unique).Count -ne $choices.Count) {
            Add-PlanError "Human gate '$id' choices must be unique."
        }
        if ((Get-PlanProperty $node 'default_safe_action') -notin $choices) {
            Add-PlanError "Human gate '$id' default_safe_action must be one of its choices."
        }
        $actionClass = Get-PlanProperty $node 'action_class'
        if ($actionClass -notin @(
            'decision', 'read-only', 'local-reversible',
            'external-write', 'irreversible'
        )) {
            Add-PlanError "Human gate '$id' requires a valid action_class."
        }
        if ($actionClass -in @('external-write', 'irreversible') -and
            (Get-PlanProperty $node 'default_safe_action') -ne 'stop') {
            Add-PlanError "Human gate '$id' must default to stop for $actionClass."
        }
    }
    if ($kind -eq 'join' -and @($dependsOn).Count -lt 2) {
        Add-PlanError "Join node '$id' requires at least two dependencies."
    }
}

foreach ($node in $nodes) {
    foreach ($dependency in @(Get-PlanProperty $node 'depends_on')) {
        if (-not $ids.ContainsKey([string]$dependency)) {
            Add-PlanError "Node '$($node.id)' depends on missing node '$dependency'."
        }
    }
}

$visiting = [System.Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)
$visited = [System.Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)
$depthCache = @{}
function Visit-Node {
    param([string] $Id)
    if ($visiting.Contains($Id)) {
        Add-PlanError "Dependency cycle detected at node '$Id'."
        return 0
    }
    if ($depthCache.ContainsKey($Id)) { return [int]$depthCache[$Id] }
    if (-not $ids.ContainsKey($Id)) { return 0 }
    [void]$visiting.Add($Id)
    $dependencyDepths = @(
        foreach ($dependency in @(Get-PlanProperty $ids[$Id] 'depends_on')) {
            Visit-Node -Id ([string]$dependency)
        }
    )
    [void]$visiting.Remove($Id)
    [void]$visited.Add($Id)
    $maxDependencyDepth = if ($dependencyDepths.Count) {
        ($dependencyDepths | Measure-Object -Maximum).Maximum
    } else { 0 }
    $depth = 1 + [int]$maxDependencyDepth
    $depthCache[$Id] = $depth
    return $depth
}
foreach ($id in $ids.Keys) {
    $depth = Visit-Node -Id $id
    if ($depth -gt [int](Get-PlanProperty $limits 'max_graph_depth')) {
        Add-PlanError "Node '$id' exceeds limits.max_graph_depth."
    }
}

$ultraCount = @(
    $agentNodes | Where-Object {
        (Get-PlanProperty $_ 'capability') -eq 'ultra' -or
        (Get-PlanProperty $_ 'effort') -eq 'ultra'
    }
).Count
if ($ultraCount -gt [int](Get-PlanProperty $limits 'max_ultra_nodes')) {
    Add-PlanError 'Ultra node count exceeds limits.max_ultra_nodes.'
}

$verificationNodes = @(
    $agentNodes | Where-Object { (Get-PlanProperty $_ 'purpose') -eq 'verification' }
)
if ((Get-PlanProperty $plan 'risk') -eq 'high' -and $verificationNodes.Count -lt 1) {
    Add-PlanError 'High-risk plans require a planned verification agent node.'
}

$writerIds = @($normalizedWriterScopes.Keys)
for ($i = 0; $i -lt $writerIds.Count; $i++) {
    for ($j = $i + 1; $j -lt $writerIds.Count; $j++) {
        foreach ($left in @($normalizedWriterScopes[$writerIds[$i]])) {
            foreach ($right in @($normalizedWriterScopes[$writerIds[$j]])) {
                if ($left -eq $right -or
                    $left.StartsWith($right + '\', [StringComparison]::OrdinalIgnoreCase) -or
                    $right.StartsWith($left + '\', [StringComparison]::OrdinalIgnoreCase)) {
                    Add-PlanError "Write scope overlap between '$($writerIds[$i])' and '$($writerIds[$j])'."
                }
            }
        }
    }
}

$completion = Get-PlanProperty $plan 'completion'
foreach ($field in @('required_nodes', 'artifact_checks', 'evidence_checks', 'stop_conditions')) {
    if (@(Get-PlanProperty $completion $field).Count -eq 0) {
        Add-PlanError "completion.$field requires at least one entry."
    }
}
foreach ($check in @(Get-PlanProperty $completion 'artifact_checks')) {
    $path = Require-Text $check 'path' 'completion artifact check'
    $artifactSegments = $path -split '[\\/]'
    if ([IO.Path]::IsPathRooted($path) -or $artifactSegments -contains '..') {
        Add-PlanError "completion artifact path must be project-relative and cannot traverse: '$path'."
    }
    if (@($artifactSegments | Where-Object {
        $_ -match '[\. ]$' -or $_.Contains(':')
    }).Count -gt 0) {
        Add-PlanError "completion artifact path contains a Windows path alias or stream segment: '$path'."
    }
    if ((Get-PlanProperty $check 'type') -notin @('file', 'directory', 'any')) {
        Add-PlanError "completion artifact check '$path' has invalid type."
    }
    $minimumBytes = Get-PlanProperty $check 'minimum_bytes'
    if ((Get-PlanProperty $check 'type') -eq 'file' -and (
        $null -eq $minimumBytes -or
        ($minimumBytes -isnot [long] -and $minimumBytes -isnot [int]) -or
        [int64]$minimumBytes -lt 1
    )) {
        Add-PlanError "file artifact check '$path' requires integer minimum_bytes >= 1."
    }
    $minimumItems = Get-PlanProperty $check 'minimum_items'
    if ((Get-PlanProperty $check 'type') -eq 'directory' -and (
        $null -eq $minimumItems -or
        ($minimumItems -isnot [long] -and $minimumItems -isnot [int]) -or
        [int64]$minimumItems -lt 1
    )) {
        Add-PlanError "directory artifact check '$path' requires integer minimum_items >= 1."
    }
}
foreach ($check in @(Get-PlanProperty $completion 'evidence_checks')) {
    $nodeId = Require-Text $check 'node_id' 'completion evidence check'
    if (-not $ids.ContainsKey($nodeId)) {
        Add-PlanError "completion evidence check references missing node '$nodeId'."
    }
    $minimumEntries = Get-PlanProperty $check 'minimum_entries'
    if ($null -eq $minimumEntries -or
        ($minimumEntries -isnot [long] -and $minimumEntries -isnot [int]) -or
        [int64]$minimumEntries -lt 1) {
        Add-PlanError "completion evidence check '$nodeId' requires minimum_entries >= 1."
    }
}
foreach ($requiredNode in @(Get-PlanProperty $completion 'required_nodes')) {
    if (-not $ids.ContainsKey([string]$requiredNode)) {
        Add-PlanError "completion.required_nodes references missing node '$requiredNode'."
    }
}

if ($script:Errors.Count -eq 0) {
    $efficiencyScript = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) `
        'Test-OrchestrationEfficiency.ps1'
    try {
        $null = & $efficiencyScript -PlanPath $resolvedPlan
    } catch {
        Add-PlanError $_.Exception.Message
    }
}

if ($script:Errors.Count -gt 0) {
    throw ($script:Errors -join [Environment]::NewLine)
}

[pscustomobject]@{
    valid = $true
    run_id = Get-PlanProperty $plan 'run_id'
    policy_version = Get-PlanProperty $plan 'policy_version'
    node_count = $nodes.Count
    agent_node_count = $agentNodes.Count
    verification_nodes = $verificationNodes.Count
    reserved_slots = $reserved
    ultra_nodes = $ultraCount
} | ConvertTo-Json -Depth 5
