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
6. Ultra is allocated without a reason or exceeds its allowed count.
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

## Token benchmark

For every benchmark case, run the same task with the same inputs, acceptance
checks, output scope, failure policy, environment, and warm/cold cache
condition. Compare at least:

- single main agent;
- single strongest justified model/effort;
- this Skill with its selected topology.

Record `input_tokens`, `output_tokens`, `useful_output_tokens`,
`coordination_tokens`, `repeated_tokens`, `recovery_tokens`,
`wall_clock_seconds`, and an independently scored `quality_score`. Estimated
values must be labelled as estimates; never mix estimated and measured values
within one comparison.

Every baseline/candidate pair also records the same
`comparison_manifest_path` and `comparison_fingerprint`. The manifest contains
the canonical task, input manifest, acceptance checks, output scope,
environment/tool policy, cache condition, and failure policy. Benchmark
scripts compute SHA-256 from the actual manifest file and reject a self-issued
digest. Matching a human-readable `case_id` alone is not enough to establish
comparability.

`total_tokens = input_tokens + output_tokens`. `coordination_tokens` and
`recovery_tokens` are classified subsets of that total, not extra amounts to
add again. `repeated_tokens` is a subset of input Tokens.

Run:

```powershell
pwsh -File scripts/Test-OrchestrationBenchmark.ps1 `
  -BaselinePath <single-agent-metrics.json> `
  -CandidatePath <orchestrated-metrics.json>
```

For the release-level median and P90 gate, provide matching JSON arrays:

```powershell
pwsh -File scripts/Test-OrchestrationBenchmarkSuite.ps1 `
  -BaselinePath <single-agent-suite.json> `
  -CandidatePath <orchestrated-suite.json> `
  -MinimumCases 18
```

Default acceptance requires:

- at least 20% fewer total Tokens at the benchmark median;
- no Token regression at the 90th percentile;
- no more than 2 quality points lost on a 100-point rubric;
- coordination at or below 20% of candidate Tokens;
- repeated input at or below 10% of candidate input;
- wall-clock time no more than 1.25 times the baseline;
- recovery Tokens included rather than hidden.

## Acceptance

Accept a version only when:

- valid examples pass and invalid examples fail;
- no worker can become a second orchestrator;
- retries and verification remain bounded and non-recursive;
- write ownership is non-overlapping;
- interruption can resume without repeating adopted work;
- the context-efficiency preflight passes;
- representative benchmark cases clear the Token, quality, repetition,
  coordination, and latency gates;
- the main agent reports rejected reviewer advice with reasons.
