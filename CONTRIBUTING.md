# Contributing

Thank you for improving Adaptive Agent Orchestrator.

## Before opening a change

1. Keep `SKILL.md` concise and move detailed contracts into `references/`.
2. Preserve one-controller ownership. Workers must not recursively delegate.
3. Add a reproducible failure case before changing a safety rule.
4. Update `references/example-plan.json` when the plan schema changes.
5. Keep public claims narrower than the behavior enforced by scripts.

## Validate

Run from the repository root:

```powershell
pwsh -NoProfile -File `
  .\skills\adaptive-agent-orchestrator\scripts\Test-Self.ps1
```

Also validate the Skill with Codex's `skill-creator` or `quick_validate.py`.

## Pull requests

Describe:

- the failure or user need;
- the exact contract or runtime behavior changed;
- compatibility impact;
- validation performed;
- remaining risks.

Do not commit real task prompts, private thread identifiers, credentials,
personal data, or generated workflow journals.
