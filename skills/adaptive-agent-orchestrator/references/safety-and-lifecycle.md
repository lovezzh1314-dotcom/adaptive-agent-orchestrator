# Safety and lifecycle

## Before dispatch

1. Confirm user authority for background work and any model override.
2. Confirm required tools are callable.
3. Validate the serialized plan.
4. Snapshot the intended write scopes and preserve unrelated user changes.
5. Reserve verification and recovery capacity.

## Materialization gate

For a durable background thread:

1. Define one stable activation key and reserve it atomically with
   `New-ThreadActivationReservation.ps1`. The reservation must bind the saved
   role-activation preview and its hash; preparing the artifact does not replace
   showing the explanation to the user.
2. Capture the recent task list and make exactly one creation call for that
   reserved activation key.
3. Reconcile the task list regardless of whether the call reports success or
   error; use source task, creation window, and task summary.
4. If one match exists, adopt it. If multiple matches exist, stop with
   `duplicates_pending`, archive the extras, and record their disposition
   before continuing.
5. Require two captured task-list snapshots, at least five seconds apart, and
   a final snapshot at the visibility-window end before declaring no match.
6. Write the immutable reconciliation receipt with
   `Resolve-ThreadReconciliation.ps1`.
7. Retry only when the receipt confirms no match and its raw input, activation
   reservation, and receipt hashes all verify. A typed observation string alone
   is insufficient.
8. If reconciliation is unavailable or ambiguous, stop with `unknown`; never
   retry the same activation key.

A confirmed no-match replacement uses a distinct attempt activation key; an
existing reservation always blocks a second creation call for the same key.

Do not retry by switching to projectless. Do not edit Codex SQLite state. A
client-side error is not proof that no worker exists.

## Result collection gate

Independent background threads keep their final answers in their own task.
After materialization, register the real thread ID. Use `read_thread` as the
primary collection path and write a hash-bound result receipt with
`New-ThreadResultReceipt.ps1` before parent-task integration. `wait_threads`
may reduce polling for independent background threads, but it is optional. If
the runtime reports that its handler is unavailable, fall back once to bounded
thread reads; do not retry the same unavailable handler. Native subagents use
`list_agents` and `wait_agent` and never depend on `wait_threads`. Do not assume
that a sent follow-up will push the result back to the parent, and do not
interpret silence as completion.

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

## Durable lifecycle states

These states apply only after the durable control path is justified. A direct
temporary read-only worker does not create a plan, journal, stored role, or
reduced four-state lifecycle.

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
- an execution-capacity increase beyond the approved plan.

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
