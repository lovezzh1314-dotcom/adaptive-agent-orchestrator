# Role system

## Purpose

A role controls behavior, not authority, topology, model, reasoning effort, or
whether a worker exists.
The same role can run on different supported models; the same model can serve
different roles. Only the main orchestrator is a controller.

A persistent role is not necessarily a persistent thread. Preserve long-term
identity in the role contract and compact handoffs. Rotate execution sessions
when task scope or version changes, or when the thread becomes unhealthy.

## Required role contract

Every role contains:

- `id`: stable lowercase hyphenated identifier;
- optional `lifetime`: defaults to `task`; declare `project` or `user-owned`
  only when reuse changes lifecycle behavior;
- `display_name`: user-facing name;
- `mission`: one outcome-focused sentence;
- `responsibilities`: work the role must perform;
- `non_goals`: adjacent work it must refuse or return to the controller;
- `required_inputs`: inputs needed before useful work can begin;
- `deliverables`: exact return artifacts or sections;
- `evidence_rules`: how claims must be supported and uncertainty reported;
- `tool_policy`: `read-only`, `scoped-write`, or `proposal-only`;
- `question_policy`: when the role must ask, maximum questions, and what can be
  assumed safely;
- `escalation_conditions`: conditions returned to the controller instead of
  being handled autonomously;
- `identity_statement`: a concise first-person task identity included in the
  worker packet;
- `user_defined`: whether this came from the user or built-in catalog.

Missing or `task` roles exist only for one durable run. `project` roles may be reused
within the same project under the same contract. `user-owned` roles are named,
reusable roles explicitly requested or approved by the user; the controller
must not silently rewrite, delete, unpin, or downgrade them. A direct
temporary read-only worker is not a stored role and receives no persistent
role ID.

No role may create workers, expand the graph, approve its own output, execute
external or irreversible actions, or override the plan.

## Role activation protocol

Role selection and Worker activation are separate decisions. For each
candidate role, choose exactly one disposition:

- `activate-worker`: independent bounded work justifies a Worker;
- `main-agent-adopts-role`: the responsibility is useful but context overlap
  makes delegation wasteful;
- `defer-until-dependency`: useful only after a named result is accepted;
- `skip-overlap`: duplicates an active owner;
- `skip-not-relevant`: does not close an acceptance or risk gap;
- `user-requested`: explicitly requested and still checked for safe scope.

Before materializing any direct or durable Worker, tell the user:

1. role name and identity;
2. why it needs a Worker instead of the main agent;
3. concrete task;
4. responsibilities and non-goals;
5. input and context scope;
6. deliverables and evidence rules;
7. permissions and exact write scope;
8. dependencies;
9. what is lost if the Worker is omitted.

If automatic teaming was not explicitly authorized, wait for the user to
approve, remove, or redefine it. Durable agent nodes record `necessity`,
`omission_impact`, `user_disposition`, and `authorization_evidence` under
`role_activation`. Approved activation cites `user:<message-or-request>`;
automatic activation cites `policy:path:<project-relative-policy-file>`.
Render the remaining fields from the node and role contract with
`New-RoleActivationPreview.ps1`.
The validator checks only the provenance class. The main agent must verify the
cited message or policy in current context before launch; a plan string is not
proof of authority.

After materialization, report actual ID, model, status, permission scope,
dependencies, and deviations from the preview. In the no-deviation case,
compress this to role, ID, model, status, and `no deviation`; do not restate
the full preview. Do not describe a failed materialization or unreadable thread
as a Worker. Target six active Workers when the runtime supports it: no more
than four active persistent Workers and two protected transient-subagent
slots. Registered but idle roles or threads do not count. A separate
cumulative materialization ceiling covers direct, durable, later-wave, and
retry Workers. The plan validator and journal enforce one durable run; before
cross-run or direct launches, reconcile visible active Workers with
`Resolve-WorkerCapacity.ps1`.

## Built-in generic roles

Use these as defaults, then specialize with domain context:

| Role ID | Primary function | Default policy |
| --- | --- | --- |
| `explorer` | Locate facts, files, interfaces, and unknowns | read-only |
| `implementation-owner` | Produce one bounded artifact in an owned scope | scoped-write |
| `verifier` | Test claims or artifacts against explicit acceptance checks | read-only |
| `adversarial-reviewer` | Seek counterexamples, hidden assumptions, and failure modes | read-only |
| `recovery-auditor` | Reconcile journal, threads, artifacts, and unknown states | read-only |
| `integrator` | Compare evidence and prepare adoption decisions for the main agent | proposal-only |
| `domain-specialist` | Apply a named professional discipline without expanding scope | proposal-only |
| `research-evidence-curator` | Build a reusable, cross-checked source base for downstream workstreams | read-only |

The main agent remains the actual integrator and final decision owner even when
an `integrator` worker prepares a synthesis.

## Industry role packs

Industry packs are small responsibility maps, not automatic teams. Each pack
contains three or four roles so users can understand the full decision surface
without creating three or four Workers. Query the catalog, explain the
candidate roles, and load only a selected contract with
`Get-AgentRolePreset.ps1`.

Available packs:

- supply chain: demand/inventory, supply/procurement,
  logistics/fulfillment, S&OP risk integration;
- software development: requirements/impact, implementation, testing/quality,
  security/release;
- creative production: art direction, bounded production, brand/delivery
  review;
- public equity research: fundamentals, valuation, catalysts/market, thesis
  risk.

Do not imitate famous practitioners, run automatic role debates, or inject the
whole catalog into worker context.

## Research evidence role

Activate `research-evidence-curator` only when the user explicitly requests a
reusable source base or the same evidence set will serve at least two
downstream workstreams or artifacts. Keep one-off fact lookup in the main
agent. The role returns a source registry, terminology boundaries, conflicts,
freshness, unresolved questions, and a compact evidence handoff. Store these
as project artifacts; do not preserve knowledge by keeping one thread alive
indefinitely. The role is read-only and may not edit this Skill.

## Manuscript co-author pattern

The main agent is lead author and integrator. It owns the research question,
argument spine, outline, terminology, transitions, abstract, conclusion, and
final merge. Specialist roles should own bounded content, not merely review:

- a methods architect co-authors model, experiment, and robustness sections;
- a domain specialist co-authors operational interpretation, assumptions, and
  implications;
- an independent academic reviewer enters only at a quality gate and does not
  become a co-author.

Local findings return first to the owner of the affected section. Create an
additional empirical or literature role only when its evidence and artifact
are genuinely independent; never add roles to make the workflow look complete.
A co-author role uses `proposal-only` when returning section text or
`scoped-write` for an exact section path. A read-only reviewer cannot be named
as the owner of manuscript content.
When a durable manuscript run activates specialist Workers, declare the
optional `manuscript_profile` from [workflow-contract.md](workflow-contract.md)
so `co-author` and `independent-review` cannot be silently conflated. Pure
review workflows use `review-only`; this profile is never imposed on ordinary
plans.

## Creating a custom role

When the user asks for a role, first draft a contract from available context.
Ask only for missing choices that materially change behavior. Prioritize:

1. What decision or artifact must this role improve?
2. What must it never do?
3. What evidence is acceptable?
4. May it write, and to which exact paths?
5. When must it stop and ask the user or controller?
6. What return structure makes its work easy to verify?

Show the proposed identity and boundaries before every first materialization.
Save user-approved reusable roles as JSON or translate
them into project-scoped Codex custom-agent TOML only when the user wants
persistent native custom agents.

Generate a JSON draft with:

```powershell
pwsh -File scripts/New-AgentRole.ps1 `
  -Id <role-id> -DisplayName <name> -Mission <mission> `
  -Responsibilities <items> -NonGoals <items> `
  -RequiredInputs <items> -Deliverables <items> `
  -EvidenceRules <items> -ToolPolicy read-only `
  -Lifetime user-owned `
  -EscalationConditions <items> -IdentityStatement <statement>
```

Review the generated contract before adding it to a plan.

After adding it, render the node packet with `New-WorkerPacket.ps1`. The
renderer combines the role, node task, dependencies, acceptance checks,
question limit, and write scope into the exact dispatch prompt. Do not manually
remove constraints from the generated packet.

## Worker identity packet

Render the role into the worker prompt:

```text
You are the <display_name> for run <run_id>.
Mission: <mission>
You are a worker, not the orchestrator.
You may not create threads, subagents, or workflow nodes.
Responsibilities: ...
Non-goals: ...
Evidence rules: ...
Tool/write policy: ...
Ask only when: ...
Escalate when: ...
Return: ...
```

Do not use fictional biography, prestige claims, or vague personas as a
substitute for operational responsibilities and evidence standards.

## Runtime enforcement

- `read-only` and `proposal-only` roles cannot bind to writable nodes.
- The journal rejects `needs_input` after the declared question limit.
- Agent and main-node completion requires at least one evidence entry.
- The state reducer retains role ID and evidence for recovery and completion
  checks.
- A fresh session cannot reuse a thread ID already consumed by another node in
  the run.
- A declared reuse must materialize the exact prior thread and remain within
  the context turn limit.
