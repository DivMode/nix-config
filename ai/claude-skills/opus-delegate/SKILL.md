---
name: opus-delegate
description: The Opus coordinator's sub-agents — hand implementation, debugging, review or research to Claude workers through the Agent tool, each on its own model and effort (never the coordinator's) and writing in its own worktree, while the coordinator plans, supervises, reviews the real diff, and merges. Use when the user says Opus, sub-agents, or Claude agents for doing work, and for any large planned change the user has not handed to Codex.
---

# Delegate work from the Opus coordinator to Claude sub-agents

The Agent tool is the whole mechanism. Each worker is a Claude sub-agent that you, the coordinator,
start, wait on through its completion notification, and correct with `SendMessage`. The sibling
`delegate` skill hands work to Codex instead; the global Roles section says which one the user's
words pick. Repository rules outrank this skill on their own ground.

## Delegate or do it yourself

Decide for each piece, even inside a job the user said to use sub-agents for.

Delegate a piece when all of these hold:
- Its decisions are made. What remains is execution, an investigation with a clear question, or an
  independent review.
- Writing and checking the assignment costs less than doing it: many files, one transformation
  repeated across a codebase, a long edit-test-fix loop, or one of several independent pieces that
  can run side by side.
- Its result can be checked by commands or observation.

Do it yourself when any of these hold:
- It is a small fix: a few files, roughly under 50 lines, or the exact edit is already known.
- It still needs a product, architecture, or design decision, or live debugging you are steering.
- It needs credentials, deploys, production data, or a change to a live system. Those stay with
  the coordinator.

An explicit request to delegate a specific change wins. Small follow-ups after review, such as a
one-line fix, are yours. Say in one line which way each piece went and why.

## Who owns what

You: the feature actually requested, inspecting the code, product and architecture decisions,
acceptance criteria and boundaries, dispatch, reviewing the real diff, running the checks,
committing, and merging. The worker: the assigned behavior inside those boundaries, the named
checks, and an accurate report of evidence and blockers. The worker leaves its changes uncommitted.

## Choose the worker for each piece

**A worker never runs the coordinator's model.** The user, 2026-10-09: "They should not be using
the same model as the main thread. They should be using their own model and their own effort
level depending on the task." The `opus` alias resolves to the newest Opus, which is the
coordinator's own model when the coordinator runs Opus: on 2026-10-09 every worker dispatched
with `model: opus` ran `claude-opus-5-5`, the coordinator's model. Read your own model from the
system prompt ("You are powered by …") and never pass its alias. Pass `subagent_type`, `model`,
and `effort` on every dispatch.

With an Opus coordinator:

| Piece | `subagent_type` | `model` | `effort` |
| --- | --- | --- | --- |
| Fully specified mechanical edit | `implementation` | `sonnet` | `medium` |
| Bounded implementation, debugging | `implementation` | `sonnet` | `high` |
| Subtle logic, security guards, concurrency, tricky types, or a correction | `implementation` | `sonnet` | `xhigh` |
| Independent review of a diff | `general-purpose` | `sonnet` | `xhigh` |
| Plan, or research against primary sources | `Plan` / `research` | `sonnet` | `high` |
| Narrow read-only search or inspection | `Explore` | `haiku` | `low` or `medium` |

With a Sonnet or Haiku coordinator, `opus` takes the substantive rows instead, and the
coordinator's own model is still skipped.

- `model` is always explicit: omitted, it inherits the coordinator's model, which this rule
  forbids. `fable` only when the user names Fable (global rule 7).
- Verify the routing after each first dispatch:
  `grep -o '"model":"[^"]*"' <the task's output file> | sort | uniq -c` prints the model the
  worker really ran. Say it in the dispatch report.
- `effort` is the lowest level the piece needs. `max` is rare: a wrong answer is expensive and the
  reasoning genuinely hard.
- Tooling follows the type. A read-only piece goes to `Explore`, which has no edit tools; it still
  has Bash, so read-only remains an instruction for anything it runs.
- Start every worker fresh, with the assignment as its whole brief. A `fork` carries the entire
  conversation and always runs on the session's model, so never use one for delegated work.
- Workers run on this Mac. `isolation: "remote"` runs one in the cloud, where this machine's
  instructions and tools are absent; use it only when the user asks.

## One worktree per writing piece

Every piece that writes gets its own worktree, so the user's main checkout and parallel pieces never
share files. Read-only pieces need none.

- **The repository has a worktree mechanism** (a recipe or script its instructions name; some
  create per-worktree build directories): create the worktree with it, record its absolute path, and
  dispatch without `isolation`. The worker starts in your directory, not the worktree, so the
  assignment's root check and absolute paths are what keep it there.
- **It has none**: dispatch with `isolation: "worktree"`. The tool creates
  `<repo>/.claude/worktrees/agent-<id>` on branch `worktree-agent-<id>` and starts the worker there,
  with `pwd` and `git rev-parse --show-toplevel` both printing that path (observed 2026-10-09). An
  unchanged worktree is removed with its branch when the worker finishes; a changed one is kept.

## Assign

Write each brief from [assignment.md](assignment.md), the template the Codex `delegate` skill uses
too. Its REPOSITORY AND WORKTREE section carries the root check every worker runs first.

## Dispatch

1. Look for a worker that already owns the piece and continue it with `SendMessage` rather than
   starting a second (global rule 2), unless it has sat idle long enough for its prompt cache to
   go cold (global rule 10).
2. Announce one line per piece: what it does, the files it owns, and the model and effort with the
   reason.
3. One Agent call per piece, with `description` naming the piece. Independent pieces go in the same
   message so they run concurrently. Pieces own disjoint files; a piece that needs another's code
   waits until that piece is accepted. The number of workers comes from how the work splits, not a
   quota.
4. Workers run in the background and you are notified as each finishes. Until then you know nothing
   of its result: carry on with other work. A long run is not a stuck one (global rule 4).
   `TaskStop` cancels a worker.

## Correct at most once

When a criterion fails, send one targeted correction to the same worker with `SendMessage`: the
failed criterion, the evidence, and what done looks like. Brief a fresh worker instead when the
first has sat idle long enough for its prompt cache to go cold (global rule 10), or when the
correction needs a different model or effort. Dispatch it without `isolation`, naming the existing
worktree's absolute path, so it continues there rather than in a new one. Either way it is the one
correction. If the
piece still fails, stop and bring the unresolved issue back for a fresh decision.

## Accept

1. Read the handoff as claims, not evidence.
2. Check scope. `git -C <worktree> status --short --untracked-files=all` lists only paths inside
   ALLOWED WRITE SCOPE, and `git -C <worktree> reflog` shows only the worktree's creation (a fresh
   one reads `reset: moving to HEAD`), with no `commit`, `merge`, `rebase`, or `cherry-pick` entry.
   The reflog records every HEAD move, including one made before the worker reported its HEAD.
   Account for every exception before going further.
3. Read the actual diff, new untracked files included. Evaluate every acceptance criterion by
   observation and run the verification commands yourself.
4. For significant or risky work, add an independent reviewer (global rules 8 and 9): a fresh worker
   on the review row's model (never the coordinator's), given the diff, the original requirement, and the worktree's absolute path to run any
   checks in, never the implementer's summary.
5. Integrate through the repository's workflow: commit in the worktree on a branch named for the
   change, push, open the pull request, merge, and record the outcome on the issue or pull request.
6. After the merge, `git worktree remove <path>` and delete the worker's branch.

After a cancel or a failure, keep the worktree exactly as it is: run the scope check and report
what exists, for a fresh decision.

## What actually constrains a worker

- Enforced: the tool set of its `subagent_type` (edit tools present or absent; Bash can write
  either way), its `model`, and its `effort`.
- Location, not a boundary: the worktree is where the worker starts. It can still write elsewhere
  by absolute path.
- Prompt instructions only: everything under the assignment's RULES, including no commits and no
  pushes. The reflog and status checks in Accept detect a breach afterwards.
- Not covered: files outside the worktree, ignored files, and temp directories. The status check
  sees only the worktree.
