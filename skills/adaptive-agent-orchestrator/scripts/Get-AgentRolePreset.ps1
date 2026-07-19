[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet(
        'supply-chain',
        'software-development',
        'creative-production',
        'equity-research',
        'research-evidence'
    )]
    [string] $Domain,

    [string] $RoleId
)

$references = Join-Path (Split-Path -Parent $PSScriptRoot) 'references'
$catalog = Get-Content -LiteralPath (
    Join-Path $references 'role-pack-catalog.json'
) -Raw | ConvertFrom-Json -Depth 20
$pack = @($catalog.packs | Where-Object { $_.id -eq $Domain }) |
    Select-Object -First 1
if ($null -eq $pack) {
    throw "Unknown role domain '$Domain'."
}
$roles = @(Get-Content -LiteralPath (
    Join-Path $references $pack.file
) -Raw | ConvertFrom-Json -Depth 50)

if ([string]::IsNullOrWhiteSpace($RoleId)) {
    [ordered]@{
        domain = $Domain
        display_name = $pack.display_name
        selection_rule = $pack.selection_rule
        roles = @($roles | ForEach-Object {
            [ordered]@{
                id = $_.id
                display_name = $_.display_name
                mission = $_.mission
            }
        })
    } | ConvertTo-Json -Depth 10
    exit 0
}

$role = @($roles | Where-Object { $_.id -eq $RoleId }) |
    Select-Object -First 1
if ($null -eq $role) {
    throw "Role '$RoleId' does not exist in '$Domain'."
}
$role | ConvertTo-Json -Depth 20
