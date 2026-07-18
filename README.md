# Adaptive Agent Orchestrator

[简体中文](README.zh-CN.md) · [Install](#installation) · [How it works](#how-it-works) · [Limitations](#current-limitations)

`adaptive-agent-orchestrator` is a Codex Skill for planning and governing
bounded agent teams. It turns a complex request into an explicit workflow with
role contracts, dependency gates, isolated write scopes, evidence requirements,
thread rotation, compact handoffs, and deterministic completion checks.

It is designed for work where “open several agents and hope they cooperate” is
not reliable enough.

## Why use it?

Most multi-agent failures are coordination failures:

- workers receive vague or overlapping ownership;
- a single long thread accumulates unrelated tasks and versions;
- agents declare success without evidence or artifact checks;
- retries silently reuse poisoned context;
- reviewers exist, but their findings are never formally adopted or rejected.

This Skill makes those decisions explicit and testable:

- **One controller:** workers cannot recursively create more workers.
- **Bounded execution:** attempts, waves, concurrency, questions, and write
  scopes are limited in the plan.
- **Role contracts:** identity, responsibilities, non-goals, inputs,
  deliverables, evidence rules, and escalation conditions are structured.
- **Context hygiene:** project, role, workstream, and execution thread are
  separate concepts. Fresh sessions are the default.
- **Recoverable state:** plans are hashed and events are stored in a
  hash-chained append-only journal.
- **Verified handoffs:** compact handoffs are immutable, size-limited, and
  cryptographically bound to reuse packets.
- **Real completion gates:** required nodes, artifacts, evidence, and human
  decisions are validated before completion.

## What is included?

```text
skills/adaptive-agent-orchestrator/
├── SKILL.md
├── agents/openai.yaml
├── references/
│   ├── evaluation.md
│   ├── example-plan.json
│   ├── role-system.md
│   ├── routing-policy.md
│   ├── safety-and-lifecycle.md
│   └── workflow-contract.md
└── scripts/
    ├── Add-OrchestrationEvent.ps1
    ├── Get-OrchestrationState.ps1
    ├── New-AgentRole.ps1
    ├── New-OrchestrationRun.ps1
    ├── New-ThreadHandoff.ps1
    ├── New-WorkerPacket.ps1
    ├── Orchestration.Common.ps1
    ├── Test-OrchestrationCompletion.ps1
    ├── Test-OrchestrationPlan.ps1
    └── Test-Self.ps1
```

## Installation

### Install with Codex

Ask Codex:

```text
$skill-installer install https://github.com/lovezzh1314-dotcom/adaptive-agent-orchestrator/tree/main/skills/adaptive-agent-orchestrator
```

Restart Codex after installation so the Skill is rediscovered.

### Manual installation

Copy the complete Skill directory, not only `SKILL.md`.

Windows:

```powershell
Copy-Item -Recurse `
  .\skills\adaptive-agent-orchestrator `
  "$HOME\.codex\skills\adaptive-agent-orchestrator"
```

macOS or Linux:

```bash
cp -R skills/adaptive-agent-orchestrator \
  ~/.codex/skills/adaptive-agent-orchestrator
```

PowerShell 7 is required to execute the bundled deterministic scripts.

## Quick start

Invoke the Skill explicitly:

```text
Use $adaptive-agent-orchestrator to split this repository migration into
bounded workstreams, assign clear roles, reserve an independent reviewer, and
require artifact and evidence checks before completion.
```

More examples:

```text
Use $adaptive-agent-orchestrator to plan a parallel research project with
separate source ownership, a verifier, and a final synthesis gate.
```

```text
Use $adaptive-agent-orchestrator to create a custom demand-forecasting reviewer
role. Help me define its identity, non-goals, evidence rules, questions, and
escalation conditions before dispatch.
```

```text
Use $adaptive-agent-orchestrator to recover this interrupted agent workflow
from its plan and event journal without reusing failed execution context.
```

The Skill decides whether coordination is worth its cost. Small, sequential
tasks should remain in the main agent.

## How it works

```text
request
   ↓
classify complexity and risks
   ↓
define roles + workflow plan
   ↓
validate DAG, scopes, budgets, and context contracts
   ↓
dispatch dependency-ready workers in bounded waves
   ↓
record evidence and append-only lifecycle events
   ↓
independent review → controller disposition
   ↓
artifact + evidence + human-gate completion checks
```

The bundled scripts provide deterministic validation and lifecycle state. The
Codex controller remains responsible for choosing available execution tools,
materializing workers, reading real thread state, integrating results, and
performing any authorized external action.

## Validation

The v0.3.0 distribution is checked by:

- PowerShell parser validation for all bundled scripts;
- 53 self-test assertions;
- 16 rejected invalid-plan cases;
- journal, plan, and metadata tamper checks;
- dependency, idempotency, role, question, evidence, handoff, and thread
  rotation tests.

Run locally:

```powershell
pwsh -NoProfile -File `
  .\skills\adaptive-agent-orchestrator\scripts\Test-Self.ps1
```

## Current limitations

This release is a governance Skill and deterministic contract/runtime toolkit,
not a standalone agent hosting platform.

- It does not provide a universal adapter that creates Codex threads by itself.
- Real thread health, working directory, and inherited-turn checks still depend
  on the controller and execution surface.
- Natural-language context exclusions cannot erase history already injected by
  a host. Start fresh workers with only the declared packet and input artifacts.
- PowerShell 7 is the supported script runtime. Cross-platform CI currently
  validates the Windows execution path.
- v0.3.0 should be treated as an early public release; plan schemas may evolve.

## Security model

The Skill rejects recursive worker delegation, overlapping writer scopes,
unsafe relative paths, reparse-point crossings, forged plan metadata, journal
tampering, unverified handoff hashes, and human-gate completion without
recorded user evidence.

External publication, deletion, payments, account changes, and production
operations remain controller-owned actions and require explicit user authority.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Reproducible failure cases and compact
tests are preferred over broad feature requests.

## License

MIT. See [LICENSE](LICENSE).
