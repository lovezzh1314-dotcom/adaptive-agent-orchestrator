# Adaptive Agent Orchestrator

[简体中文](README.zh-CN.md) · [v0.4.2 release notes](docs/releases/v0.4.2-beta.1.md) · [Installation](#installation) · [How it works](#how-it-works) · [Limitations](#current-limitations)

`adaptive-agent-orchestrator` is a Codex Skill for reducing duplicated context
and reasoning while coordinating genuinely independent workstreams. It uses a
single-agent fast path, reference-first worker inputs, compact packets and
handoffs, progressive dispatch, selective review, delta retry, isolated write
ownership, and deterministic completion checks.

The goal is lower total task Token use. Users do not configure a Token budget,
and the Skill does not pretend it can predict the total cost of an open-ended
task. Savings must be demonstrated by fair end-to-end benchmarks.

## Why use it?

- **Less context duplication:** workers receive paths, source IDs, artifact
  pointers, and selected excerpts instead of repeated full conversations.
- **Bounded context selection:** project-wide placeholder references are
  rejected; optional selection diagnostics stay in the controller, not worker
  prompts.
- **Progressive disclosure:** the Skill body stays compact; references and
  project files are read only when a workstream needs them.
- **Single-agent by default:** small, sequential, high-overlap, and narrow-edit
  tasks remain in the main agent.
- **Progressive dispatch:** wave 1 contains one worker. Later workers require
  an earlier validated result or disjoint context.
- **Direct-worker fast path:** one temporary read-only worker does not require
  a durable plan, journal, stored role, or miniature lifecycle.
- **Visible role activation:** every Worker is explained before creation and
  reported after materialization; choosing a role never forces a Worker.
- **Four-Worker ceiling:** the controller counts direct and durable Workers
  together; deterministic scripts enforce four inside each durable run.
- **On-demand professional roles:** compact supply-chain, software, creative,
  and equity-research packs expose only the selected contract.
- **Manuscript co-authorship:** methods and domain specialists can own bounded
  sections while the main agent preserves the argument spine and final voice.
- **Explicit role lifetime:** task, project, and user-owned roles cannot be
  silently conflated; user-owned reusable roles are never auto-downgraded.
- **Risk-based review:** low-risk work skips a reviewer; medium-risk work
  samples critical output; high-risk work may use one independent reviewer.
- **Delta retry:** retries carry the previous-output pointer, failure evidence,
  and repair instruction rather than replaying the full packet; delta mode is
  accepted only for the same node in a hash-checked failed run.
- **One controller:** workers cannot recursively create workers.
- **Recoverable execution:** immutable plans, hash-chained events, handoffs
  only when resume/reuse needs them, write-scope checks, and completion gates.

## Design inputs

v0.4 adopts narrow mechanisms from primary GitHub sources:

- [Agent Skills specification](https://github.com/agentskills/agentskills):
  metadata → Skill body → resources-on-demand progressive disclosure;
- [OpenAI Skill Creator](https://github.com/openai/skills/blob/main/skills/.system/skill-creator/SKILL.md):
  keep only task-essential instructions in the Skill and execute scripts
  without loading them into model context;
- [Supabase Agent Skills guidance](https://github.com/supabase/agent-skills/blob/main/AGENTS.md):
  make every paragraph justify its Token cost and move advanced detail into
  references;
- [Superpowers parallel-agent guidance](https://github.com/obra/superpowers/blob/main/skills/dispatching-parallel-agents/SKILL.md):
  dispatch only independent domains and isolate worker context;
- [Acontext](https://github.com/memodb-io/Acontext): retrieve explicit skill
  files on demand instead of injecting opaque memory into every context;
- [oh-my-codex](https://github.com/Yeachan-Heo/oh-my-codex): treat economy
  routing as a product concern.

We intentionally do not copy long mandatory reasoning rituals, live DAG
rewrites, reviewer ensembles, full-log replay, or user-facing Token budgets.
GPT-5.6 already performs ordinary decomposition and tool choice; repeating
those instructions increases overthinking and context cost.

## Included files

```text
skills/adaptive-agent-orchestrator/
├── SKILL.md
├── agents/openai.yaml
├── references/
│   ├── context-efficiency.md
│   ├── evaluation.md
│   ├── example-plan.json
│   ├── role-pack-catalog.json
│   ├── role-system.md
│   ├── roles-creative-production.json
│   ├── roles-equity-research.json
│   ├── roles-software-development.json
│   ├── roles-supply-chain.json
│   ├── routing-policy.md
│   ├── safety-and-lifecycle.md
│   └── workflow-contract.md
└── scripts/
    ├── Add-OrchestrationEvent.ps1
    ├── Get-OrchestrationState.ps1
    ├── Get-AgentRolePreset.ps1
    ├── New-AgentRole.ps1
    ├── New-OrchestrationRun.ps1
    ├── New-RoleActivationPreview.ps1
    ├── New-ThreadHandoff.ps1
    ├── New-WorkerPacket.ps1
    ├── Orchestration.Common.ps1
    ├── Test-OrchestrationBenchmark.ps1
    ├── Test-OrchestrationBenchmarkSuite.ps1
    ├── Test-OrchestrationCompletion.ps1
    ├── Test-OrchestrationEfficiency.ps1
    ├── Test-OrchestrationPlan.ps1
    └── Test-Self.ps1
```

## Installation

Ask Codex:

```text
$skill-installer install https://github.com/lovezzh1314-dotcom/adaptive-agent-orchestrator/tree/main/skills/adaptive-agent-orchestrator
```

Restart Codex after installation. Manual installation copies the complete
`skills/adaptive-agent-orchestrator` directory into
`$HOME/.codex/skills/adaptive-agent-orchestrator`.

PowerShell 7.5 or later is required for the deterministic scripts.

## Quick start

```text
Use $adaptive-agent-orchestrator only if this migration contains genuinely
independent workstreams. Keep shared context in the main agent, give workers
references instead of copied content, and dispatch progressively.
```

```text
Use $adaptive-agent-orchestrator to create a custom demand-forecasting reviewer
role. Help me define its identity, non-goals, evidence rules, questions, and
escalation conditions before dispatch.
```

```text
Use $adaptive-agent-orchestrator for this supply-chain study. Show the compact
role map first, explain which responsibilities stay with the main agent, and
ask before creating any Worker I have not auto-authorized.
```

```text
Use $adaptive-agent-orchestrator to recover this interrupted workflow from its
plan and event journal without replaying failed context.
```

## Compared with official Codex subagents

Official Codex subagents are the execution primitive. This Skill is a
context-efficiency and governance layer above that primitive; it does not
replace the official feature.

| Capability | Official subagents | Adaptive Agent Orchestrator |
| --- | --- | --- |
| One-off delegation | Built in and simpler | Stays out of the way |
| Context selection | Controller judgment | Reference-first inputs, exclusions, overlap check |
| Dispatch timing | Prompt-driven | One-worker first wave, validated-result dependency |
| Review | Controller judgment | Risk-only or sampled; no default reviewer ensemble |
| Retry | Session-dependent | Delta repair packet and failure-class rules |
| Write ownership | Prompt/sandbox dependent | Rejects overlapping writer scopes |
| Recovery | Thread history and summaries | Hashed plan, append-only journal, immutable handoff |
| Completion | Main agent consolidation | Node, artifact, evidence, and human-gate checks |
| Token savings | Not automatically measured | Offline end-to-end benchmark gate |

Use official subagents directly for short, obvious delegation. Use this Skill
when coordination itself creates risk or repeated context.

## How it works

```text
request
   ↓
single-agent fast path unless workstreams are independent
   ↓
reference-first plan + context-overlap check
   ↓
one worker in wave 1
   ↓
validate evidence/artifact
   ↓
optional later wave only when it adds new accepted value
   ↓
risk-based review + main-agent integration
   ↓
artifact/evidence/human-gate completion checks
```

The scripts validate structure and lifecycle state. The Codex controller still
selects available execution tools, materializes workers, reads real thread
state, integrates results, and performs authorized external actions.

## Validation

The v0.4.2-beta.1 candidate currently passes:

- PowerShell parser validation for all 15 scripts;
- 369 self-test assertions;
- 36 intentionally invalid negative-test plans correctly rejected;
- plan, metadata, journal, handoff, dependency, idempotency, ownership,
  context-overlap, progressive-dispatch, short-packet, and completion tests;
- a synthetic single-case benchmark test.

Run:

```powershell
pwsh -NoProfile -File `
  .\skills\adaptive-agent-orchestrator\scripts\Test-Self.ps1
```

## Current limitations

- This is a governance Skill, not a standalone agent host.
- Natural-language exclusions cannot erase history already injected by a host;
  use fresh workers and explicit input references.
- Exact context-overlap checks cannot detect two differently named references
  that contain the same semantics; the main agent must still reject them.
- Separate durable runs do not share a machine ledger. The controller enforces
  the root-task Worker ceiling and must reconcile visible state after recovery.
- Token usage is diagnostic only when the execution surface exposes it.
- The 20% median savings target is a release benchmark target, not yet a
  production claim. Synthetic tests do not prove real Token savings.
- Windows 10 with PowerShell 7.6.3 is verified; macOS and Linux are not yet.

## Security model

The Skill rejects recursive delegation, overlapping writer scopes, unsafe
paths, forged run metadata, journal tampering, unverified handoff hashes, and
human-gate completion without recorded user evidence. External publication,
deletion, payments, account changes, and production operations remain
controller-owned and require user authority.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Reproducible failure cases and compact
tests are preferred over broad feature requests.

## License

MIT. See [LICENSE](LICENSE).
