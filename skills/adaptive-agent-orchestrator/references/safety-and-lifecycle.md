# Safety and lifecycle

## Before dispatch

1. Confirm user authority for background work and any model override.
2. Confirm required tools are callable.
3. Validate the serialized plan.
4. Snapshot the intended write scopes and preserve unrelated user changes.
5. Reserve verification and recovery capacity.

## Materialization gate

For a durable background thread:

1. Create one real worker using the correct project.
2. Read the returned thread immediately.
3. Require a real thread, working directory, and turn state.
4. Stop the batch if the thread cannot be read or is not materialized.

Do not retry by switching to projectless. Do not edit Codex SQLite state. A
client-side ID without a readable thread is not a worker.

## Session rotation

Use a fresh execution thread at task, scope, or version boundaries. Keep a
thread only while all of these remain true:

- it represents the same continuity key and atomic workstream;
- it is readable and healthy;
- its inherited turns stay within the plan limit;
- its prior result has an immutable compact handoff whose SHA-256 matches the
  planned `prior_handoff_hash`;
- reuse saves more context than it imports.

`systemError`, a changed write scope, or a new version forces rotation. Preserve
the role, evidence, decisions, artifacts, unresolved risks, and next action in
the handoff; limit the complete serialized payload and do not copy raw
reasoning or unrelated chat history. A failed fresh attempt must receive a new
thread ID on retry.

## Worker contract

Every task packet must say:

- it is a worker, not an orchestrator;
- it cannot create threads or subagents;
- its exact read and write scope;
- its dependencies and role in the plan;
- its required return format;
- its acceptance tests;
- how to report missing information.

## Lifecycle states

Use:

```text
planned -> launch_reserved -> materializing -> materialized -> running -> needs_input
        -> completed -> validated -> adopted -> archived
        -> failed | cancelled | rejected | unknown
```

Only the main agent may mark `validated` or `adopted`.
Completion evidence uses a typed pointer (`artifact:`, `test:`, `source:`, or
`observation:`). Treat it as an auditable claim, not proof; verify the target
before validation.

Archive disposable workers only after:

- the thread is completed and idle;
- artifacts and claims have been checked;
- the result is adopted;
- no follow-up audit depends on the live thread.

Persistent project roles remain unarchived and should be pinned when supported.

## Human gates

Require a human gate for:

- external publishing or messaging;
- payment, account, permission, or production changes;
- destructive or irreversible action;
- material scope expansion;
- a budget increase beyond the approved plan.

Workers may prepare these actions but may not execute them.

These rules are control-plane policy, not a claim that prompts provide a
security sandbox. When the runtime can restrict worker tools or permissions,
apply those restrictions. Otherwise treat worker compliance as untrusted and
verify traces and proposed actions in the main agent.

## Recovery

Resume from the event journal:

1. Validate that `plan.json` still matches the intended goal.
2. Derive the latest state of every node.
3. Reuse completed and validated artifacts.
4. Re-read live durable threads instead of recreating them.
5. Dispatch only dependency-ready incomplete nodes.
6. Record any plan revision as an event; never silently rewrite history.

The journal uses ordered sequence numbers and a SHA-256 hash chain. Treat a
sequence gap or hash mismatch as corruption and stop recovery. `unknown` is
fail-closed: reconcile it manually or reject it; never recreate it
automatically.
