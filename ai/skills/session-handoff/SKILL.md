---
name: session-handoff
description: Hand the current work to a fresh agent session in a new Herdr pane, with a handoff document and its first prompt.
disable-model-invocation: true
argument-hint: "What should the next session do?"
---

# Session handoff

Move the work to a fresh session so it continues with a clean context. The handoff is finished only when a new agent is **working** on it in its own Herdr pane. A written document alone is not a handoff.

Arguments, when given, describe what the next session will focus on. Shape every step around them.

## 1. Reconcile what is already happening

Before writing anything, establish the current truth, because work may have moved on since this conversation last looked.

- `herdr agent list`: note any live session in the same repository, its pane ID and its title. A session that already owns the task gets the handoff instead of a new one; ask the user only when you can't tell.
- The repository's durable record: open issues and PRs, recently merged PRs, and the default branch's latest commits (`gh issue list`, `gh pr list --state all`, `git fetch && git log origin/<default>`). Anything already done drops out of the handoff.

Done when every item you intend to hand over is confirmed still open and owned by nobody else.

## 2. Checkpoint durably

The handoff document lives in a temp directory and will be lost, so it only points at durable material.

- Record each decision, plan and finding that exists only in this conversation where it belongs: on the issue the work belongs to, in a new issue, or in an ADR or PR.
- Commit and push finished work. Leave nothing important only in this transcript.

Done when the next session could rebuild the plan from GitHub and the repository alone.

## 3. Write the handoff document

Write it to `$TMPDIR` under a new, task-specific file name. Check the path is free first, and never overwrite an existing file there; another session may own it.

Sections, in this order:

1. **Repository and state:** absolute repository root, default-branch commit, and the instruction to verify the root with `pwd` and `git rev-parse --show-toplevel`.
2. **The task, in order:** numbered items, each pointing at its issue or PR by URL or number. Put anything time-bound first, with its exact time in the relevant timezone.
3. **Decisions already made:** each with its reason and the issue that records it, so the next session doesn't re-litigate them.
4. **How to work:** rules this session learned the hard way, each tied to the incident that taught it, plus current machine facts (resources, live sibling sessions and their panes, which sessions must not be disturbed).
5. **Gotchas:** non-obvious technical facts, each with a file or symbol pointer.
6. **Unpushed or local-only work:** what it is, and that it must be kept.
7. **Suggested skills:** the skills the next session should invoke, and when.

Reference artifacts instead of copying them. Redact secrets, tokens and personal data.

Done when a reader with no access to this conversation knows the first action to take and why.

## 4. Transfer time-bound jobs

Session-only scheduled jobs (CronCreate) die with this session. For each one:

1. Put its time and steps in the handoff's first task item.
2. Tell the next session to schedule it itself.
3. Cancel it here with CronDelete, so it runs exactly once.

Done when every pending job has exactly one owner.

## 5. Start the new session in Herdr

Follow the `herdr` skill. In short:

1. Confirm `HERDR_ENV=1`. Without Herdr, give the user the one-line prompt to paste into a new session in the repository root, and stop here.
2. Inspect the caller's geometry with `herdr pane layout --pane "$HERDR_PANE_ID"`. Split right if the pane is wide, down if it is narrow or tall, using `--no-focus` and `--cwd <repository root>`.
3. Start the agent in the new pane with `herdr agent start <task-name> --kind claude --pane <new pane>`, unless the user asked for another kind.
4. Send the first prompt with `herdr agent prompt <task-name> "..."`. The prompt names the handoff path, says to carry it out in order, names the first action explicitly, and says to act and then report.
5. Wait about 15 seconds, then `herdr agent get <task-name>`.

Done when the agent's status is `working` and its title or recent output shows it picked up the handoff. If it stalls or blocks, read its output with `herdr agent read` and resolve it before reporting.

## 6. Report

Tell the user:

- the pane ID and agent name;
- the handoff path;
- what the new session will do first;
- which jobs moved to it;
- anything this session left unresolved.

Leave the other sessions' panes as they are.
