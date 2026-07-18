# Context efficiency

The goal is lower total task Token use through less reading, copying, and
duplicated reasoning. Do not ask the user for a Token budget and do not predict
the total cost of an open-ended task.

## Progressive disclosure

Load information in three stages:

1. keep Skill metadata sufficient for activation;
2. keep `SKILL.md` limited to the core operating contract;
3. read references and project files only when the active workstream needs
   them.

Worker inputs are references first: stable file paths, source IDs, artifact
IDs, line ranges, or handoff hashes. Inline content only when the worker cannot
access the source or the selected excerpt is materially smaller than the
lookup instruction.

Do not preload every reference "for completeness." A script can run without
being read into model context.

## Context selection gate

Reject placeholder or project-wide inputs such as `path:.`, `path:*`,
`ref:all`, `source:all`, an entire repository, or a full conversation. A
worker that needs broad discovery should first receive a bounded directory,
file pattern, or source index rather than the whole project. The controller
may record a one-line `context.selection_reason` for borderline discovery or
overlap cases; it is optional diagnostic metadata and never enters a worker
packet.

Do not create a context index for ordinary work. A durable project may keep a
small machine-readable artifact catalog only when many later workstreams will
reuse stable artifacts. The catalog stores pointers and dependency metadata,
not copied content, summaries of every file, or another planning narrative.

## Dispatch filter

Use the main agent when work is strongly sequential, needs most of the same
context, changes one small file, or lacks an independently checkable output.

When orchestration is justified:

- launch one worker in wave 1;
- give it one bounded workstream and explicit acceptance checks;
- launch a later wave only after an earlier worker result is validated;
- keep exact context-input overlap at or below the plan threshold;
- forbid recursive workers and speculative races in the lean profile.

The overlap checker catches repeated input references. The main agent still
rejects semantic duplication when different labels point to substantially the
same material.

## Compact packets and handoffs

The default packet contains only identity, task, boundaries, selected
references, exclusions, acceptance checks, and handoff format. `-Full` exists
for debugging, not routine dispatch.

Create a handoff only when a later session must resume or reuse the work.
When required, handoffs contain:

- smallest useful summary;
- decisions and unresolved risks;
- evidence and artifact pointers;
- exact next action.

Never paste the full worker transcript or hidden reasoning into another
worker. A handoff includes only selected evidence pointers relevant to its
summary, decisions, risks, and next action; the selected pointers must be a
subset of the machine-recorded node evidence. Let later workers open only the
cited artifacts they need.

## Adoption check

Before dispatching another optional worker, the main agent checks whether the
last adopted result changes the plan, opens a required dependency, or closes
an acceptance gap. Continue only when at least one is true. This is a
controller decision, not a new planner, router, score, or generated artifact.

## Delta retry

Retry with the previous-output pointer, failure evidence, and exact repair
instruction. Do not resend the full original packet unless the input scope
changed or the prior context is unavailable. Tool, permission, and invalid-task
failures return to the main agent instead of triggering blind retries.

`New-WorkerPacket.ps1` requires `RetryRunDirectory` in delta mode and verifies
that the same plan and node are recorded there in a hash-checked `failed`
state. An initial attempt or an unrelated run cannot self-declare itself a
delta retry.

## Review policy

Low-risk work skips a dedicated reviewer. Medium-risk work samples one
independent check when it covers a material failure mode. High-risk work may
use a reviewer, but the main agent integrates directly; do not create a
separate integrator worker merely to restate two outputs.

## Measurement

Usage telemetry is optional diagnostic data, not a runtime budget. Offline
benchmarks compare the complete task under the same inputs, environment,
acceptance checks, and failure policy. A release may claim Token savings only
from measured benchmark results; structural heuristics alone are not proof.

## Design evidence

- [Agent Skills specification](https://github.com/agentskills/agentskills)
  uses progressive disclosure: metadata, Skill body, then resources on demand.
- [OpenAI Skill Creator](https://github.com/openai/skills/blob/main/skills/.system/skill-creator/SKILL.md)
  keeps only task-essential instructions in the Skill and separates resources
  that do not need to enter context.
- [Supabase Agent Skills guidance](https://github.com/supabase/agent-skills/blob/main/AGENTS.md)
  asks authors to justify each paragraph's Token cost and keep advanced detail
  in references.
- [Superpowers parallel-agent guidance](https://github.com/obra/superpowers/blob/main/skills/dispatching-parallel-agents/SKILL.md)
  dispatches only independent domains. We adopt that narrow rule, not its
  broader mandatory reasoning rituals.
- [Acontext](https://github.com/memodb-io/Acontext) exposes skill files on
  demand instead of injecting opaque memory into every context.
