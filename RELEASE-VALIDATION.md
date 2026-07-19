# Release validation receipt

Release: `0.5.0`
Policy version: `0.5.0`
Date: `2026-07-19`

## Environment

- OS: Microsoft Windows 10.0.22621
- PowerShell: 7.6.3 Core
- Platform: Win32NT

## Commands

```powershell
$skill = '.\skills\adaptive-agent-orchestrator'

Get-ChildItem "$skill\scripts" -Filter '*.ps1' | ForEach-Object {
  $tokens = $null
  $errors = $null
  [Management.Automation.Language.Parser]::ParseFile(
    $_.FullName,
    [ref]$tokens,
    [ref]$errors
  ) | Out-Null
  if ($errors) { throw $errors }
}

pwsh -NoProfile -File "$skill\scripts\Test-Self.ps1"

python `
  "$HOME\.codex\skills\.system\skill-creator\scripts\quick_validate.py" `
  $skill
```

## Results

- Exit code: 0
- PowerShell scripts parsed: 18
- Self-test assertions: 438 passed
- Intentional invalid-plan negative cases: 47 correctly rejected
- Skill Creator validation: `Skill is valid!`
- Self-hosted live review: the existing read-only architecture challenger
  reviewed the frozen working tree without modifying files or creating child
  Workers. It independently rechecked immutable retry routing, authorization
  boundaries, team/workflow separation, active-capacity order, and actual
  model recording; final result was `GREEN`, with no remaining P0 or P1
  findings.

The self-test covers deterministic mode and model resolution, active-capacity
reservation, local plans, role activation, compact role packs, short/full
packets, context efficiency, benchmark, usage diagnostics, lifecycle, journal,
handoff, and completion logic. Synthetic
benchmark metrics do not prove measured Token savings on production tasks. The
live self-hosted review verifies one real materialization path, not every host
or failure mode.
