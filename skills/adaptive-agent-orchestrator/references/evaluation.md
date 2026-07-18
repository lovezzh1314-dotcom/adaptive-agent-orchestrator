# Evaluation

## Static checks

- No scaffolding marker or template placeholder remains.
- Frontmatter contains only `name` and `description`.
- Every linked reference and script exists.
- `agents/openai.yaml` names the skill correctly.
- Example plans pass `Test-OrchestrationPlan.ps1`.
- Invalid plans fail with actionable messages.
- Rendered worker packets preserve role identity, non-goals, evidence rules,
  question limits, and exact write scope.
- Completion fails when required nodes, artifacts, or evidence are missing.

## Architecture challenge

Ask an independent reviewer to test at least these failures:

1. A worker tries to invoke the orchestrator recursively.
2. Two writers claim overlapping directories.
3. A dependency references a missing node.
4. A loop has no bound or stopping condition.
5. A race has no cancellation policy.
6. Ultra is allocated without a reason or exceeds its budget.
7. Verification and retry reserves are consumed by initial workers.
8. A background thread returns an ID but cannot be read.
9. A worker completes but its artifact fails acceptance checks.
10. Resume sees completed journal events but missing artifacts.
11. A node references a missing or incomplete role contract.
12. A role title implies authority that its tool policy does not grant.
13. A custom role asks more questions than its declared question policy allows.
14. A read-only or proposal-only role attempts a write.
15. A worker exceeds its role's maximum question count.
16. A worker reports completion without a concrete evidence pointer.
17. All nodes finish but a required artifact is missing or empty.
18. A fresh node reuses another node's thread ID.
19. A reuse node points at a different thread than `prior_thread_id`.
20. A persistent role accumulates unrelated versions in one execution thread.
21. A handoff omits evidence, unresolved risks, or the exact next action.

Each finding must include a minimal fix and a test that would have caught it.

## Forward tests

Run at least three fresh-context scenarios:

- **Quick:** two read-only codebase investigations using native subagents.
- **Team:** a durable writer plus independent read-only reviewer with disjoint
  ownership.
- **Workflow:** a three-stage DAG with a bounded verification loop and human
  gate.

Do not tell test agents the expected answer. Give them the skill and the raw
task. Inspect actual plans, tool choices, artifacts, and stopping behavior.

## Acceptance

Accept a version only when:

- valid examples pass and invalid examples fail;
- no worker can become a second orchestrator;
- budget accounting includes retries and verification;
- write ownership is non-overlapping;
- interruption can resume without repeating adopted work;
- the main agent reports rejected reviewer advice with reasons.
