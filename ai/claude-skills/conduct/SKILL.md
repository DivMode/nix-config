---
name: conduct
description: Lead a piece of work from one T3 Code thread — split it, hand each piece to the right model with T3's delegate_task (Claude, Codex, Antigravity), check the results and merge. The owner's opt-in to cross-vendor routing for that work. `$conduct <task>` in a T3 Code Claude thread.
argument-hint: "<the task or backlog to lead>"
disable-model-invocation: true
---

# Conduct

The task: `$ARGUMENTS`

You are the lead for this task, in a T3 Code thread. You plan, split, delegate,
check and merge. Write code yourself only when a piece is too small to hand off.
Invoking this skill does not choose a worker: implementation goes to Codex
unless the owner names another (global Roles), as the routes below say.

## How T3 Code runs the team

T3 Code's orchestrator tools are in this session. Use them for delegated
children. Run the independent review through the Codex CLI as described below.

- `delegate_task` starts a child thread on any provider and model. Use
  `mode: "async"` (the default) and `isolation: "worktree"` for anything that
  edits files, so each child has its own checkout. A finished child **wakes
  this thread**: do not poll or wait on it. Hand out everything that can run
  now, then end your turn; you resume when a child finishes.
- `task_status` and `task_cancel` manage children you started.
  `orchestrator_capabilities` lists the providers and models this machine has.
- `schedule_task` for recurring work, only when the owner asks for it.
- Send messages only to children this thread started. Never `t3_thread_send`,
  interrupt or steer any other thread: the owner forbids anything that nudges
  other sessions.

## Route by job

| Job | Target | Effort |
| --- | --- | --- |
| Parallel implementation slices | Codex `gpt-6.2-sol` (Claude Opus 5.5 only when the owner names it) | high |
| Clear-spec, many-file or mechanical work, scripts, migrations | Codex `gpt-6.2-sol` | medium for mechanical, high by default, xhigh for subtle logic |
| A long, hard problem (design, a deep bug) | Claude Fable 5.2 | high; it hands execution back to you |
| Independent review of the finished diff | `codex review -c model="gpt-6.2-sol" -c sandbox_mode="read-only"` | high by default |
| Optional second opinion on a diff or plan | Claude Opus 5.5, or Antigravity Neon | high, read-only brief |
| Lookups and chores | Claude Haiku 5.5 | default |

Effort is never `max` to start. Use it only after `high` visibly failed on that
same piece. Global rule 9 applies whoever implemented the work. Give the
reviewer the actual diff and the original requirement.

## Brief every child completely

A child sees nothing of this thread. Each `delegate_task` brief states:

1. the goal and the acceptance criteria, as observable checks;
2. the absolute repository root, and that it must run `pwd` and
   `git rev-parse --show-toplevel` and confirm them before touching files;
3. the files it owns, and that it must not edit anything else;
4. the verification command, run through
   `membrake exec --label "<repo>: <what>" -- …` for anything heavy;
5. that it leaves its changes **uncommitted** and reports what it changed and
   the command output, pasted, not summarised;
6. that it never signals processes it did not start, never runs `op`, and
   never bypasses a hook or guard.

Two children never own the same file. If they must, the second waits for the
first to merge.

## Check, then merge

- Read each child's report as claims. Inspect the actual diff in its
  worktree and run the acceptance checks yourself.
- Before merging or reporting completion, independently review the final diff.
  Follow global rule 9: with nothing committed on top of the base use
  `codex review --uncommitted`; otherwise commit the final edits, confirm nothing
  is untracked, and use `--base <branch>`. Always add
  `-c sandbox_mode="read-only"` and pass the requirement in
  `-c developer_instructions=...`. For SQL privileges, grants,
  roles, or security boundaries, start with a Claude reviewer through
  `opus-delegate`. For a mixed diff, use a custom Codex review prompt for the
  remaining diff and the original requirement. Repeat the review after a
  correction, a fix after review, or a combination of pieces.
- Commit through the repository's signed path, push, open the PR, and watch
  its checks until green. Nothing reaches `main` without a PR.
- One correction per child, by messaging that same child. If it still fails,
  decide afresh: re-brief smaller, move it to another model, or do it yourself.
- A usage limit on one vendor: move the slice to another.
- A long-running child is not a stuck child. Check `task_status`; never
  relaunch a task because it is slow.

## Stop only for

Spending money, deleting data, production migrations, secrets, or a decision
that changes the goal. Everything else is yours to decide; say what you chose.

## Report

When the task is done: what merged (PR links), what each model did, what was
verified and how, and what is still open.
