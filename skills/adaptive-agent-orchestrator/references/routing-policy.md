# Routing policy

## Decision axes

Do not compare all mechanisms on one axis.

| Axis | Choices | Governing question |
| --- | --- | --- |
| Topology | main, native subagent, durable thread | Where should the work and history live? |
| Workflow | direct, parallel, pipeline, DAG, loop, race, human gate | How do results and decisions depend on one another? |
| Compute | model class and reasoning effort | How much capability is justified for this node? |

The main agent is always the only orchestrator.

## Topology selection

Choose `main` when any of these dominates:

- orchestration costs more than the task;
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

- the role should persist across versions or turns;
- independent history, pinning, or recovery matters;
- the task is long-running or has a separate workspace;
- explicit per-worker routing or lifecycle inspection is required.

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
- the node is read-only; v0.3 does not permit Ultra writers;
- the node cannot delegate or orchestrate;
- a cheaper attempt has failed, or the user explicitly requested Ultra for
  this node.

Ultra is a reasoning allocation, not permission to create more agents.

## Default limits

Use stricter project instructions when present.

```text
max_concurrent_nodes: 4
max_total_agent_nodes: 8
max_new_nodes_per_wave: 3
max_attempts_per_node: 2
retry_reserve: 1
verification_reserve: 1
max_ultra_nodes: 1
max_agent_depth: 1
max_graph_depth: 6
max_dynamic_nodes: 1
max_forks: 0
```

At least one verification slot is mandatory for a high-risk or multi-artifact
run. A worker may never consume a reserved slot without a revised, validated
plan.

## Escalation ladder

1. Check whether the task packet, inputs, and acceptance test were defective.
2. Send one bounded clarification to the same materialized worker.
3. Retry once with a stronger effort/model or let the main agent take over.
4. Use Ultra only when its gate is satisfied.
5. Stop when the evidence says the plan is wrong; do not spend the budget merely
   to complete the original graph.
