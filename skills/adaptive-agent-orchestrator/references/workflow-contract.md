# Workflow contract

## Plan structure

A durable plan is a JSON object with:

- `schema_version`: currently `"1.0"`;
- `policy_version`: currently `"0.3.0"`, used to validate and replay the run;
- `run_id`: unique, stable identifier;
- `orchestrator`: the single controller identity and delegation authority;
- `goal`: concrete outcome;
- `mode`: `auto`, `quick`, `team`, or `workflow`;
- `risk`: `low`, `medium`, or `high`;
- `limits`: bounded concurrency, total nodes, attempts, reserves, depth, and
  Ultra allocation;
- `roles`: validated behavioral contracts referenced by nodes;
- `nodes`: work items;
- `completion`: global success and stopping criteria.

Each node contains:

```json
{
  "id": "review-architecture",
  "kind": "agent",
  "topology": "native-subagent",
  "workflow": "parallel",
  "depends_on": [],
  "role_id": "adversarial-reviewer",
  "purpose": "verification",
  "task": "Find control-plane and recovery failures",
  "capability": "strong",
  "effort": "high",
  "read_only": true,
  "write_scope": [],
  "acceptance": ["Every finding includes a reproducible failure scenario"],
  "max_attempts": 1,
  "allow_delegation": false,
  "context": {
    "session_policy": "fresh",
    "continuity_key": "architecture-review",
    "max_prior_turns": 0,
    "inputs": ["Validated proposal", "Acceptance criteria"],
    "excluded": ["Unrelated project conversations"],
    "handoff_path": "artifacts/handoffs/review.json",
    "handoff_max_chars": 4000,
    "rotate_on": ["system-error", "scope-change", "version-boundary"]
  }
}
```

Allowed node kinds:

- `agent`: work executed by an agent;
- `main`: work retained by the main agent;
- `human-gate`: a decision that requires user input;
- `join`: deterministic dependency barrier.

Allowed topology for agent nodes:

- `native-subagent`;
- `background-thread`.

Workflow values describe behavior, not execution products:

- `direct`;
- `parallel`;
- `pipeline`;
- `dag`;
- `loop`;
- `race`.

## Thread and context contract

Treat the project, role, workstream, and execution thread as different objects:

- the project is the durable container;
- the role is the durable behavioral identity;
- the workstream is the bounded line of responsibility;
- the thread is one execution session that may be rotated.

Every agent node declares:

- `session_policy`: `fresh` by default, or explicitly justified `reuse`;
- `continuity_key`: stable workstream identity;
- `inputs`: context that must be supplied;
- `excluded`: nearby context that must not be inherited;
- `handoff_path`: unique compact state artifact;
- `handoff_max_chars`: 500–8000 characters for the complete serialized
  handoff, not only its summary;
- `rotate_on`: at least `system-error`, `scope-change`, and
  `version-boundary`;
- `max_prior_turns`: `0` for fresh sessions and `1..6` for reuse.

Only a background thread may use `reuse`. Reuse also requires
`prior_thread_id`, `prior_handoff`, `prior_handoff_hash`, and `reuse_reason`.
`prior_handoff_hash` is the SHA-256 digest of the exact stored handoff file.
Handoffs are append-once artifacts: never overwrite a prior execution's
handoff. Before dispatch, the controller must verify the file hash, read the
actual thread, and reject reuse when either is missing or changed, the thread
is unhealthy or over the turn limit, or it no longer represents the same
workstream. Never fork a long thread merely to preserve identity; that copies
the context problem.

Every handoff requires an exact `next_action` and an explicit
`risk_disposition` of `none`, `open`, or `mitigated`; do not substitute a
generic default. A fresh context must not carry any reuse-only field.

## Dependency and cycle rules

- Every dependency must reference an existing node.
- Node IDs must be unique.
- The dependency graph must be acyclic.
- A loop is represented by one bounded `loop` node with explicit
  `max_iterations` and `stop_condition`; never create a graph cycle.
- A race must define `winner_condition` and `cancel_losers: true`.
- A human gate must define the default safe action for timeout or absence.
- An Ultra node sets both `capability` and `effort` to `ultra`, remains
  read-only, and records `ultra_authorization` as `user-requested` or
  `escalated-after-failure`. An escalation also names
  `prior_attempt_node_id`, whose failed state is checked before launch.

## Ownership rules

- `read_only: true` requires an empty `write_scope`.
- A `read-only` or `proposal-only` role may bind only to a read-only node.
- A node may be more restrictive than its role, never less restrictive.
- Every writable node lists exact files or directories.
- Write scopes are project-relative, canonical, free of traversal and wildcard
  syntax, and resolved against real paths before dispatch to detect links.
- Concurrent writable nodes may not overlap scopes.
- The main agent owns final integration even when workers write disjoint files.

## Completion contract

Global completion must define:

- required nodes;
- structured artifact checks with a project-relative `path`, `type`, and
  optional minimum size or item count;
- structured evidence checks naming a node and minimum evidence entries;
- unresolved-risk threshold;
- termination conditions for budget, repeated failure, unavailable tools, and
  rejected approvals.

Finishing all nodes is not success if acceptance checks fail.
Every agent or main node completion event includes at least one typed evidence
pointer using `artifact:`, `test:`, `source:`, or `observation:`. A generic
success claim without a type is rejected. Typed pointers improve auditability
but do not prove provenance; the main agent still verifies the referenced
material before marking the node `validated`.
