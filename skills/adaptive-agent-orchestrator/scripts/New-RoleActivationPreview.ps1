[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $PlanPath,

    [Parameter(Mandatory)]
    [string] $NodeId,

    [string] $OutputPath
)

$plan = Get-Content -LiteralPath (Resolve-Path -LiteralPath $PlanPath) -Raw |
    ConvertFrom-Json -Depth 100
$node = @($plan.nodes | Where-Object { $_.id -eq $NodeId }) |
    Select-Object -First 1
if ($null -eq $node -or $node.kind -ne 'agent') {
    throw "Agent node '$NodeId' was not found."
}
$role = @($plan.roles | Where-Object { $_.id -eq $node.role_id }) |
    Select-Object -First 1
if ($null -eq $role) {
    throw "Role '$($node.role_id)' was not found."
}
if ($null -eq $node.role_activation) {
    throw "Agent node '$NodeId' has no role_activation."
}

$permission = if ($node.read_only) {
    'read-only; no workspace writes'
} else {
    'scoped-write: ' + (@($node.write_scope) -join ', ')
}
$dependencies = if (@($node.depends_on).Count -eq 0) {
    'none'
} else {
    @($node.depends_on) -join ', '
}
$inputs = @($node.context.inputs) -join '; '
$excluded = @($node.context.excluded) -join '; '
$responsibilities = @($role.responsibilities) -join '; '
$nonGoals = @($role.non_goals) -join '; '
$deliverables = @($role.deliverables) -join '; '
$evidence = @($role.evidence_rules) -join '; '

$preview = @"
## Proposed Worker

- Role: $($role.display_name) [$($role.id)]
- Mission: $($role.mission)
- Identity: $($role.identity_statement)
- Why a Worker is needed: $($node.role_activation.necessity)
- Concrete task: $($node.task)
- Responsibilities: $responsibilities
- Non-goals: $nonGoals
- Inputs and context scope: $inputs
- Excluded context: $excluded
- Topology/session: $($node.topology) / $($node.context.session_policy)
- Deliverables: $deliverables
- Evidence rules: $evidence
- Permissions and write scope: $permission
- Dependencies: $dependencies
- If omitted: $($node.role_activation.omission_impact)
- Authorization basis: $($node.role_activation.user_disposition)
- Authorization evidence: $($node.role_activation.authorization_evidence)
"@

if ($OutputPath) {
    $parent = Split-Path -Parent $OutputPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Set-Content -LiteralPath $OutputPath -Value $preview -Encoding utf8
}
$preview
