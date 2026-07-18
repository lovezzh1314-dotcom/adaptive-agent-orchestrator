[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')]
    [string] $Id,
    [Parameter(Mandatory)][string] $DisplayName,
    [Parameter(Mandatory)][string] $Mission,
    [Parameter(Mandatory)][string[]] $Responsibilities,
    [Parameter(Mandatory)][string[]] $NonGoals,
    [Parameter(Mandatory)][string[]] $RequiredInputs,
    [Parameter(Mandatory)][string[]] $Deliverables,
    [Parameter(Mandatory)][string[]] $EvidenceRules,
    [Parameter(Mandatory)]
    [ValidateSet('read-only', 'scoped-write', 'proposal-only')]
    [string] $ToolPolicy,
    [Parameter(Mandatory)][string[]] $EscalationConditions,
    [Parameter(Mandatory)][string] $IdentityStatement,
    [ValidateSet('task', 'project', 'user-owned')]
    [string] $Lifetime = 'task',
    [ValidateRange(0, 3)][int] $MaxQuestions = 2,
    [string[]] $AskWhen = @('A required input is missing'),
    [switch] $UserDefined,
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$role = [ordered]@{
    id = $Id
    display_name = $DisplayName
    mission = $Mission
    responsibilities = @($Responsibilities)
    non_goals = @($NonGoals)
    required_inputs = @($RequiredInputs)
    deliverables = @($Deliverables)
    evidence_rules = @($EvidenceRules)
    tool_policy = $ToolPolicy
    question_policy = [ordered]@{
        ask_when = @($AskWhen)
        max_questions = $MaxQuestions
        safe_assumptions = @()
    }
    escalation_conditions = @($EscalationConditions)
    identity_statement = $IdentityStatement
    user_defined = [bool]$UserDefined
}
if ($Lifetime -ne 'task') {
    $role.Insert(1, 'lifetime', $Lifetime)
}

$json = $role | ConvertTo-Json -Depth 20
if ($OutputPath) {
    $parent = Split-Path -Parent $OutputPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        throw "Output directory does not exist: $parent"
    }
    $json | Set-Content -LiteralPath $OutputPath
}
$json
