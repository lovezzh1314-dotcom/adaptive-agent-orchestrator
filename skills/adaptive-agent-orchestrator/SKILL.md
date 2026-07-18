---
name: adaptive-agent-orchestrator
description: Plan, route, supervise, and recover complex Codex work across native subagents, durable Codex background threads, and dependency-aware workflows. Use when a task has two or more independent workstreams, needs independent verification, benefits from model/reasoning routing, requires a DAG, race, loop, human gate, durable recovery, or a persistent reviewer. Do not use for simple questions, status checks, single-file small edits, strongly sequential work, or external production actions.
---

# Adaptive Agent Orchestrator

Act as the only control plane. Treat agent topology, workflow shape, and model
effort as separate decisions:

1. Choose **where work runs**: main agent, native subagent, or durable background
   thread. Decide separately whether that execution needs a fresh session or a
   bounded reuse.
2. Choose **how work is connected**: direct, parallel, pipeline, DAG, bounded
   loop, race, or human gate.
3. Choose **how much reasoning to allocate**: economical worker, strong worker,
   or one explicitly justified Ultra escalation.
4. Choose **which role contract governs behavior**: mission, responsibilities,
   non-goals, evidence, deliverables, permissions, questions, and escalation.

Never let a worker invoke this skill, create another worker, or become a second
orchestrator.

## Start with a plan

Read [routing-policy.md](references/routing-policy.md) and
[workflow-contract.md](references/workflow-contract.md). When roles are not
already unambiguous, also read [role-system.md](references/role-system.md).
State:

- why orchestration is justified;
- nodes, dependencies, owners, and acceptance checks;
- execution topology for every agent node;
- concurrency, total-worker, retry, and Ultra budgets;
- write scopes and human gates;
- completion and stopping conditions.
- explicit context inputs, excluded context, session policy, and handoff path.

Use the smallest suitable built-in role. When the user requests a custom role,
help define it before dispatch. Do not infer authority from a title. Validate
the role contract independently from model and topology.

For a durable or multi-stage run, serialize the plan to JSON, validate it with:

```powershell
pwsh -File scripts/Test-OrchestrationPlan.ps1 `
  -PlanPath <plan.json> -WorkspaceRoot <project-root>
```

Do not dispatch until the plan passes.

Render every agent node into a complete, role-bound worker packet:

```powershell
pwsh -File scripts/New-WorkerPacket.ps1 `
  -PlanPath <plan.json> -NodeId <agent-node-id> `
  -WorkspaceRoot <project-root> -OutputPath <packet.md>
```

Dispatch the rendered packet without weakening its identity, evidence,
question, escalation, or write boundaries.

Default every agent node to a fresh execution session. A persistent role is an
identity and memory contract, not permission to keep one thread alive forever.
Reuse a background thread only for the same bounded workstream, with a compact
prior handoff, a healthy readable thread, and a declared turn limit. Handoffs
are immutable; bind every reuse packet to the stored handoff's SHA-256 digest.

## Select execution topology

- Keep work in the **main agent** when it is small, sequential, sensitive to
  full conversational context, or cheaper than coordination.
- Use a **native subagent** for bounded, temporary, independently checkable
  exploration, testing, or review that should return to the current task.
- Use a **durable background thread** for long-running work, persistent roles,
  independent task history, explicit model routing, or recovery across turns.
- Use workflow semantics across either topology. A DAG is not itself a fourth
  kind of agent.

Use only capabilities actually exposed in the current session. If a required
thread or subagent tool is unavailable or a created thread cannot be
materialized and read back, stop dispatch and continue safely in the main
agent. Never modify Codex databases to repair orchestration.

## Execute in bounded waves

Read [safety-and-lifecycle.md](references/safety-and-lifecycle.md).

1. Reserve capacity for verification and one recovery attempt before starting.
2. Start one real worker as a health probe when using durable threads.
3. Dispatch only dependency-ready nodes, in waves of at most three new nodes.
4. Keep one writer per file or directory. Reviewers remain read-only.
5. Require structured returns: conclusion, evidence or changes, validation,
   unresolved risks, and questions.
6. Validate worker claims and artifacts in the main agent before adoption.
7. Record every lifecycle change for durable runs.
8. Rotate a thread on system error, scope change, or version boundary; preserve
   continuity through a compact handoff rather than full conversational history.

Initialize a durable run with:

```powershell
pwsh -File scripts/New-OrchestrationRun.ps1 `
  -PlanPath <plan.json> -WorkspaceRoot <project-root> `
  -RunDirectory <run-directory>
```

Record events with:

```powershell
pwsh -File scripts/Add-OrchestrationEvent.ps1 `
  -RunDirectory <run-directory> -NodeId <id> -Status running `
  -Message "worker started" -IdempotencyKey "<run>:<node>:<attempt>:running"
```

Derive resumable state with:

```powershell
pwsh -File scripts/Get-OrchestrationState.ps1 `
  -RunDirectory <run-directory>
```

Record concrete evidence pointers when a worker completes. The runtime rejects
completion without evidence and rejects questions beyond the role contract.

After validation, write the bounded handoff declared by the node:

```powershell
pwsh -File scripts/New-ThreadHandoff.ps1 `
  -RunDirectory <run-directory> -NodeId <id> `
  -Summary <bounded-summary> -NextAction <exact-next-action>
```

## Apply quality gates

Require an independent reviewer for high-risk or multi-artifact runs. Give the
reviewer raw plans and artifacts, not the intended answer. The reviewer must
produce falsifiable failure scenarios, minimal fixes, executable tests, and
questions for the main agent.

Use an Ultra worker only when [routing-policy.md](references/routing-policy.md)
allows it. Ultra changes reasoning depth; it does not own orchestration and
must not delegate.

Before delivery, run the checks in
[evaluation.md](references/evaluation.md). Report adopted findings, rejected
findings with reasons, model/effort distribution, retries, unfinished risks,
and whether durable workers were retained or archived.

For durable runs, require the executable completion gate:

```powershell
pwsh -File scripts/Test-OrchestrationCompletion.ps1 `
  -RunDirectory <run-directory>
```

Do not call the run successful unless this gate passes.

## External-action boundary

Workers may prepare material for publishing, sending, deleting, paying,
changing accounts, or modifying production. Only the main agent may perform
those actions, and only with the authority present in the user request.
