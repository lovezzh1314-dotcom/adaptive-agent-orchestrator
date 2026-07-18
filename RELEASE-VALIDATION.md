# Release validation receipt

Release: `0.3.0-beta.1`  
Policy version: `0.3.0`  
Date: `2026-07-18`

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
- PowerShell scripts parsed: 10
- Self-test assertions: 53 passed
- Invalid-plan cases: 16 rejected
- Skill Creator validation: `Skill is valid!`

The self-test covers the deterministic local plan, role, packet, lifecycle,
journal, handoff, and completion logic. It uses simulated thread identifiers;
it is not evidence that a live Codex execution surface materialized or
isolated those threads.
