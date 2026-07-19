---
name: adaptive-agent-orchestrator
description: Reduce total context and duplicated reasoning while coordinating genuinely independent Codex workstreams across native subagents and durable background threads. Use for complex work that benefits from isolated ownership, selective verification, durable recovery, or parallel evidence gathering. Keep small, sequential, high-overlap, and full-conversation tasks in the main agent.
---

# Adaptive Agent Orchestrator

Act as the only orchestrator. The product goal is lower total task Token use,
not more agents and not a user-configured Token budget.

GPT-5.6 already decomposes work, chooses tools, and summarizes results. Do not
add generic reasoning rituals or repeat model-native instructions. Add only
controls that prevent duplicated context, ownership conflicts, runaway
delegation, unverifiable completion, or lost recovery state.

Never let a worker create another worker or invoke this Skill.

## Decide whether to orchestrate

Stay in the main agent when work is small, strongly sequential, needs most of
the same context, changes one narrow surface, or lacks an independently
checkable result.

Orchestrate only when at least two workstreams are genuinely independent or an
independent check covers a material risk. Start with one worker. A later worker
must depend on an earlier validated result or own disjoint context.

For one temporary, read-only worker, dispatch directly with a compact task
packet. Do not create a durable plan, journal, or custom role unless recovery,
write ownership, cross-turn reuse, or an approval gate actually needs it.
The direct worker has no persistent role ID, project attachment, or pin. If the
user asks for a named, reusable, project, or persistent role, use the durable
role path instead.

Load references only when their path is active:

- read [context-efficiency.md](references/context-efficiency.md) only for a
  nontrivial context, retry, handoff, or review decision;
- read [routing-policy.md](references/routing-policy.md) only when selecting a
  topology, capacity, or model;
- read [workflow-contract.md](references/workflow-contract.md) only for a
  durable run;
- read [role-system.md](references/role-system.md) only for stored, custom,
  reused, or industry roles. A direct temporary native subagent uses the
  compact fields in this file and does not load the role manual.

## Explain every Worker before creation

A role is a responsibility contract, not a command to create a worker. The
main agent may adopt a role itself, defer it, or skip it when the work overlaps.
Never fill available worker seats merely because roles exist.

Before every direct or durable Worker, show its role, necessity versus main
agent execution, execution form (`native subagent` or `independent background
agent`) and why that form fits the task lifecycle, concrete task,
responsibilities, non-goals, input scope, deliverables, evidence rules,
permissions, dependencies, and omission impact. If the user has not explicitly
authorized automatic teaming, wait for approval or a requested change. Durable
nodes record `user:<message-or-request>` for explicit approval or
`policy:path:<project-relative-policy-file>` for automatic authorization;
never infer authority from the plan itself. Render the exact preview with:

```powershell
pwsh -File scripts/New-RoleActivationPreview.ps1 `
  -PlanPath <plan.json> -NodeId <agent-node-id> `
  -OutputPath <run>/receipts/<node>-role-preview.md
```

Show that preview in commentary before invoking any creation tool. The preview
file is evidence that the explanation was prepared, not proof that the user
saw it; the main agent must still present it. Durable background reservations
must bind this exact file and its hash. For direct native subagents, do not
create a run merely for this evidence, but the same user-facing explanation
must precede `spawn_agent`.

After materialization, report the role, actual execution form, actual Worker or
thread ID, actual model, status, and any deviation from the preview. Repeat
permissions or dependencies only when they changed. A failed health probe is
not proof of absence; it consumes no seat only after task-list reconciliation
confirms that nothing materialized. Target at most six active Workers: four
active background threads plus two reserved native-subagent slots. Clamp this
to the platform's actual capacity. Idle registered roles or threads do not
consume active slots. Keep a separate cumulative
materialization ceiling for later waves and retries. If recovery cannot
reconcile the root-task count, launch no new Worker.

A creation-call error is not proof that no Worker was created. Before retrying
any failed or ambiguous materialization, reconcile the recent task list using
the source task, creation window, and task summary. Adopt one matching task;
stop and archive extras if duplicates exist. Make only one creation call per
stable activation key. Retry only when reconciliation confirms that no matching
task materialized; if reconciliation is unavailable or ambiguous, stop and
report `unknown` instead of retrying. Atomically reserve the activation key
with `New-ThreadActivationReservation.ps1` and the saved role-preview path
before the creation call, then
produce the reconciliation decision with `Resolve-ThreadReconciliation.ps1`;
do not infer it from the creation-call status alone. A confirmed no-match
retry uses a new attempt activation key. Put the exact
`<activation_key>...</activation_key>` and
`<source_thread_id>...</source_thread_id>` markers in the background task
prompt so the visible task-list preview can be matched without guessing.

An independent background agent does not automatically return its result to
the parent task. Register its thread ID and use `read_thread` as the primary
result-collection path. `wait_threads` is only an optional background-thread
wait optimization; it is not the native-subagent wait mechanism. If its
handler is unavailable, fall back once to bounded thread reads rather than
retrying the wait call. Native subagents use `list_agents` and `wait_agent`;
independent background agents use `list_threads` and `read_thread`.
Record the final turn and adopted/rejected findings with
`New-ThreadResultReceipt.ps1`; do not treat silence as completion or continue
final integration without the receipt.

Use industry role packs only when a professional responsibility would improve
the result. First list the compact catalog, then load only the selected
contract:

```powershell
pwsh -File scripts/Get-AgentRolePreset.ps1 -Domain supply-chain
pwsh -File scripts/Get-AgentRolePreset.ps1 `
  -Domain supply-chain -RoleId demand-inventory-planner
```

## Minimize context

Use reference-first inputs: stable paths, source IDs, artifact IDs, line
ranges, and handoff hashes. Do not inline material a worker can open itself.
Do not preload every reference. Reject broad references such as a repository
root, `all files`, or an entire conversation. For durable nodes, record a
one-line `selection_reason` explaining why the selected references are the
smallest sufficient set.

For durable plan nodes, use `New-WorkerPacket.ps1` without `-Full`. Full
packets are debugging aids. A direct temporary worker gets the same compact
fields inline from the main agent; do not create a plan merely to call the
script.

Do not pass full transcripts or hidden reasoning between agents. Pass the
smallest conclusion, evidence pointers, unresolved risks, and next action.
Create a handoff only when another session must resume or reuse the work.

Retry with the prior-output pointer, failure evidence, and exact repair
instruction. Do not resend the original context unless it changed or became
unavailable. After any deterministic failure, creating another Worker requires
the user to authorize that exact failed event. The premise manifest is audit
context, not an automatic retry authorization.

## Use durable control only when needed

For durable, multi-stage, multi-writer, or recoverable work, record nodes,
waves, dependencies, roles, write scopes, selected context, exclusions,
acceptance checks, and completion conditions. Use one writer per path;
reviewers are read-only.

```powershell
pwsh -File scripts/Test-OrchestrationPlan.ps1 `
  -PlanPath <plan.json> -WorkspaceRoot <project-root>

pwsh -File scripts/Test-OrchestrationEfficiency.ps1 `
  -PlanPath <plan.json>

pwsh -File scripts/New-WorkerPacket.ps1 `
  -PlanPath <plan.json> -NodeId <agent-node-id> `
  -WorkspaceRoot <project-root> -OutputPath <packet.md>
```

If efficiency validation rejects the plan, use the main agent. Do not weaken
context-overlap, progressive-dispatch, or delta-retry rules to force a team.

## Select execution topology

- Use a native subagent for temporary, bounded, independently checkable work.
- Use a background thread when independent history, explicit routing,
  recovery, or reuse across turns matters.
- Reuse a thread only for the same bounded workstream with a compact immutable
  handoff and verified hash. Otherwise use a fresh session.
- Use only execution tools actually available. If materialization or read-back
  fails, stop dispatch and continue safely in the main agent.

Resolve `auto`, capacity, and verification profile with
`Resolve-OrchestrationPreset.ps1`. Resolve the dispatch model with
`Resolve-WorkerModel.ps1`. Before every launch, use
`Resolve-WorkerCapacity.ps1` with observed active persistent and transient
counts; registered but idle agents do not count. Automatically use Luna only
for bounded mechanical work and Sol for ordinary judgment, implementation,
writing, or review. Treat Terra as explicit and experimental. Before any model
or effort escalation, explain the change and obtain user confirmation unless a
bounded policy already authorizes it. Ultra always needs explicit per-node
confirmation.

## Execute progressively

1. Start one worker as the first wave.
2. Dispatch only dependency-ready nodes.
3. Validate its evidence and artifacts in the main agent.
4. Before another wave, ask whether the adopted result changes the plan,
   opens a required dependency, or closes an acceptance gap. If none is true,
   stop dispatch. Do not create a separate optimizer to answer this.
5. Skip dedicated review for low-risk work. Sample critical output for
   medium-risk work. Use an independent reviewer for high-risk or
   cross-artifact consistency risk.
6. Let the main agent integrate directly. Do not create an integrator worker
   merely to restate worker outputs.
7. Stop optional workers when a wave adds no accepted evidence, coverage, or
   material risk reduction. The main agent may continue improving the task.

For manuscripts, the main agent owns the argument spine, outline, voice,
abstract, conclusion, and final merge. A methods or domain role may co-author
its bounded section and return revisions to that same owner; do not reduce
every specialist to a reviewer. Keep one independent academic reviewer for the
quality gate. Findings return to the original section owner before final
integration.

For durable runs:

```powershell
pwsh -File scripts/New-OrchestrationRun.ps1 `
  -PlanPath <plan.json> -WorkspaceRoot <project-root> `
  -RunDirectory <run-directory>

pwsh -File scripts/Add-OrchestrationEvent.ps1 `
  -RunDirectory <run-directory> -NodeId <id> -Status running `
  -Message "worker started" -IdempotencyKey "<run>:<node>:<attempt>:running"

pwsh -File scripts/Get-OrchestrationState.ps1 `
  -RunDirectory <run-directory>
```

Record typed evidence on completion. Derive compact state from the journal;
never replay the full journal into a model. Write an immutable handoff with
`New-ThreadHandoff.ps1` only when `context.handoff_required` is true.

Before delivery, run `Test-OrchestrationCompletion.ps1`. Default to reporting
the task result, not internal orchestration traffic. Expose adopted/rejected
findings, retries, thread disposition, or measured usage only when the user
asks, they affect confidence, an unresolved risk remains, or user action is
required.

Use [evaluation.md](references/evaluation.md) only while developing or
benchmarking this Skill. Do not load it during ordinary user work.

## External actions

Workers may prepare external or production changes. Only the main agent may
publish, send, delete, pay, change accounts, or modify production, and only
with authority from the user request.
