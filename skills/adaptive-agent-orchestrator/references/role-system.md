# Role system

## Purpose

A role controls behavior, not authority, topology, model, or reasoning effort.
The same role can run on different supported models; the same model can serve
different roles. Only the main orchestrator is a controller.

A persistent role is not necessarily a persistent thread. Preserve long-term
identity in the role contract and compact handoffs. Rotate execution sessions
when task scope or version changes, or when the thread becomes unhealthy.

## Required role contract

Every role contains:

- `id`: stable lowercase hyphenated identifier;
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

No role may create workers, expand the graph, approve its own output, execute
external or irreversible actions, or override the plan.

## Built-in roles

Use these as defaults, then specialize with domain context:

| Role ID | Primary function | Default policy |
| --- | --- | --- |
| `explorer` | Locate facts, files, interfaces, and unknowns | read-only |
| `implementation-owner` | Produce one bounded artifact in an owned scope | scoped-write |
| `verifier` | Test claims or artifacts against explicit acceptance checks | read-only |
| `adversarial-reviewer` | Seek counterexamples, hidden assumptions, and failure modes | read-only |
| `recovery-auditor` | Reconcile journal, threads, artifacts, and unknown states | read-only |
| `integrator` | Compare evidence and prepare adoption decisions for the main agent | proposal-only |
| `domain-specialist` | Apply a named professional discipline without expanding scope | read-only |

The main agent remains the actual integrator and final decision owner even when
an `integrator` worker prepares a synthesis.

## Creating a custom role

When the user asks for a role, first draft a contract from available context.
Ask only for missing choices that materially change behavior. Prioritize:

1. What decision or artifact must this role improve?
2. What must it never do?
3. What evidence is acceptable?
4. May it write, and to which exact paths?
5. When must it stop and ask the user or controller?
6. What return structure makes its work easy to verify?

Show the proposed identity and boundaries before first use when they are
materially ambiguous. Save user-approved reusable roles as JSON or translate
them into project-scoped Codex custom-agent TOML only when the user wants
persistent native custom agents.

Generate a JSON draft with:

```powershell
pwsh -File scripts/New-AgentRole.ps1 `
  -Id <role-id> -DisplayName <name> -Mission <mission> `
  -Responsibilities <items> -NonGoals <items> `
  -RequiredInputs <items> -Deliverables <items> `
  -EvidenceRules <items> -ToolPolicy read-only `
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
