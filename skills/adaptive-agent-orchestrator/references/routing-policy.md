# Routing policy

## Decision axes

Do not compare all mechanisms on one axis.

| Axis | Choices | Governing question |
| --- | --- | --- |
| Topology | main, native subagent, durable thread | Where should the work and history live? |
| Workflow | direct, parallel, pipeline, DAG, loop, race, human gate | How do results and decisions depend on one another? |
| Compute | model class and reasoning effort | How much capability is justified for this node? |

The main agent is always the only orchestrator.

## Model-native minimum

Do not duplicate capabilities GPT-5.6 already supplies. The Skill should decide
and enforce only what needs a durable or deterministic guarantee. Keep
decomposition, prompt phrasing, and ordinary tool choice implicit unless a
failure makes one of them material.

Avoid live DAG rewriting, reviewer ensembles, repeated dynamic role creation,
and model-facing full journal replay. Each adds another reasoning loop without
a default economic case.

## Efficiency before topology

Do not create a worker until
[context-efficiency.md](context-efficiency.md) clears the plan. Do not predict
a task-total Token budget. Reduce total use by limiting duplicated context,
unnecessary workers, repeated reviews, full-packet retries, and transcript
replay.

Default to `lean`. Use `balanced` only when a measurable quality or latency
benefit justifies more verification. Use `quality` only when the user
explicitly prioritizes quality or a high-risk gate requires it.

## Topology selection

Choose `main` when any of these dominates:

- coordination is likely larger than the independently useful work;
- most workers would receive substantially the same input context;
- the task is strongly sequential;
- one small write surface cannot be isolated;
- external or irreversible action is central;
- available agent tools cannot be verified.

Choose `native-subagent` when all are true:

- the work is temporary and bounded;
- a concise result can return to the current task;
- durable independent history is unnecessary;
- the node has a clear acceptance test.

Choose `background-thread` when any are true:

- independent history, pinning, or recovery matters;
- the task is long-running or has a separate workspace;
- explicit per-worker routing or lifecycle inspection is required.

A persistent role alone does not justify a persistent thread. Preserve role
identity in its contract; choose a background thread only when the workstream
history, recovery, or cross-turn execution itself must persist.

## Model and effort classes

Use capability classes in plans so the skill remains portable:

| Class | Intent |
| --- | --- |
| `economy` | extraction, classification, formatting, broad scans |
| `standard` | normal implementation, research, drafting, testing |
| `strong` | architecture, ambiguous debugging, adversarial review |
| `ultra` | one exceptional escalation or final high-risk adjudication |

Resolve a class to a currently available model only at dispatch time. Never
invent an unavailable model ID.

`ultra` requires all of the following:

- the selected surface and model actually support it;
- the plan states a concrete quality reason;
- `limits.max_ultra_nodes` has remaining capacity;
- the node is read-only; v0.4 does not permit Ultra writers;
- the node cannot delegate or orchestrate;
- the user explicitly requested Ultra for this node.

Ultra is a reasoning allocation, not permission to create more agents.

## Default limits

Use stricter project instructions when present.

```text
max_concurrent_nodes: 2
max_total_agent_nodes: 4
max_new_nodes_per_wave: 2
max_attempts_per_node: 2
retry_reserve: 1
verification_reserve: 1
max_ultra_nodes: 1
max_agent_depth: 1
max_graph_depth: 6
max_dynamic_nodes: 1
max_forks: 0
```

At least one verification slot is mandatory for a high-risk run. A
multi-artifact run reserves verification only when cross-artifact consistency
is a material risk. Low-risk lean runs set `verification_reserve` to zero.
A worker may never consume a reserved slot without a revised, validated plan.

These are safety ceilings, not targets. Start with one worker. A second worker
must own disjoint context or independently reduce a material risk. In lean
mode, do not use speculative races and do not allocate a reviewer to merely
summarize or approve another worker.

The controller applies the four-Worker ceiling across the root task, including
direct, durable, later-wave, and retry Workers. The deterministic journal
enforces it within one run; separate runs do not share a ledger. A
materialization that fails its immediate health probe is not counted as a
Worker.

## Escalation ladder

1. Check whether the task packet, inputs, and acceptance test were defective.
2. Send one bounded clarification to the same materialized worker.
3. Retry once with a stronger effort/model or let the main agent take over.
4. Use Ultra only when its gate is satisfied.
5. Stop when the evidence says the plan is wrong or a wave adds no new value;
   do not complete the original graph merely because it exists.

Do not retry missing inputs, malformed packets, permission failures, or
unavailable tools with a stronger model. Correct the input or return to the
main agent.
