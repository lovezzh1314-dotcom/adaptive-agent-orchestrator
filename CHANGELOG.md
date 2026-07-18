# Changelog

## 0.4.2-beta.1 - 2026-07-18

Role-activation release. Plan policy version advances to `0.4.2`.

- Separate role selection from Worker creation: the main agent may adopt,
  defer, or skip a role instead of filling available seats.
- Require a pre-creation explanation of necessity, task, boundaries, context,
  output, evidence, permissions, dependencies, and omission impact; report the
  actual Worker identity and status after materialization.
- Bind durable explicit approval to `user:` evidence and automatic teaming to
  an existing project-relative `policy:path:` file instead of trusting a naked
  plan flag.
- Enforce a hard maximum of four Workers per root task and reject plan limits
  above four. Failed health probes do not count as created Workers.
- Permit a replacement startup after a confirmed `startup_unmaterialized`
  failure without consuming retry reserve; report materialized Worker count
  separately from launch attempts.
- Add compact on-demand role packs for supply chain, software development,
  creative production, and public equity research; each contains only three or
  four operational roles and exact-role queries do not load neighbors.
- Add a manuscript co-author pattern: the main agent owns the argument spine
  and final merge, methods and domain specialists own bounded sections, and
  one independent academic reviewer enters only at the quality gate.
- Add an optional manuscript profile that distinguishes bounded co-authors,
  research contributors, and independent reviewers without affecting ordinary
  or review-only plans.
- Add deterministic role-activation preview and role-preset query scripts,
  plus negative tests for missing authorization and excessive Worker limits.

## 0.4.1-beta.1 - 2026-07-18

Friction-reduction release. Plan policy version advances to `0.4.1`.

- Reject project-wide placeholder context references; keep selection reasons
  optional, controller-only diagnostics that never enter worker packets.
- Keep artifact catalogs optional and limited to durable projects with repeated
  reuse; ordinary work does not generate a context index.
- Classify stored roles as task, project, or user-owned. Direct temporary
  workers have no persistent role identity; user-owned roles cannot be
  silently rewritten or downgraded.
- Make handoffs opt-in through `context.handoff_required`; nodes that return
  directly no longer write a handoff artifact, and required handoffs carry
  only selected evidence pointers already present in machine state.
- Add a controller-only adoption check before later waves without adding a new
  planner, router, optimizer, score, or generated artifact.
- Enforce progressive waves at runtime and allow dependency-free later workers
  only when their context is truly disjoint and earlier waves are terminal.
- Clarify that the full lifecycle and hash journal apply only to durable work,
  not the direct temporary read-only fast path.

## 0.4.0-beta.1 - 2026-07-18

Context-efficiency release. Plan policy version advances to `0.4.0`.

- Remove user-facing Token budgets and task-total cost prediction from the
  runtime path.
- Add reference-first context, exact input-overlap checks, progressive
  one-worker-first dispatch, risk-only review, and delta-retry policy.
- Add a default short worker packet; full packets are debug-only.
- Bind delta-retry packets to the same hash-checked plan and a node recorded in
  a real failed run; initial attempts cannot self-declare delta mode.
- Add fair benchmark gates for Token use, quality, repetition, coordination,
  recovery, and latency.
- Bind benchmark comparison fingerprints to actual manifest files, reject
  duplicate cases, and prevent command-line weakening of release thresholds.
- Make lean mode and the single-agent fast path the default.
- Skip dedicated low-risk reviewers and sample medium-risk verification.
- Add model-native guidance: do not duplicate GPT-5.6 decomposition, tool
  choice, or ordinary reasoning in the Skill schema.
- Document narrowly adopted ideas from Agent Skills, OpenAI Skill Creator,
  Supabase, Superpowers, Acontext, and oh-my-codex while rejecting
  high-overhead reasoning rituals.

## 0.3.0-beta.1 - 2026-07-18

First public beta release. The plan policy version remains `0.3.0`.

- Add structured role, node, dependency, evidence, and completion contracts.
- Add bounded lifecycle and hash-chained event journal.
- Add fresh/reuse execution context policies and forced rotation boundaries.
- Add immutable compact handoffs with SHA-256 reuse binding.
- Add worker packet rendering and user-defined role generation.
- Add deterministic plan, completion, path, tamper, and self-tests.
- Add English and Simplified Chinese publication documentation.

## Planned

- Verified materialization receipts for real Codex execution surfaces.
- Reference indexes and enforceable read scopes.
- Structured unresolved-risk completion thresholds.
- Runtime adapters for join, loop, and race workflows.
- Telemetry calibration across repeated benchmark cases.
