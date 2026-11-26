---
name: pursue
description: Arm a goal this session may not stop short of — this Mac's replacement for Claude Code's /goal, which cannot run under the managed-only hook policy. `/pursue <checkable condition>` arms it, `/pursue` shows it, `/pursue clear` cancels it.
argument-hint: "<checkable condition> [--hours N] | clear | (empty: status)"
disable-model-invocation: true
---

# Pursue a goal

A managed Stop hook refuses to let this session end its turn while its goal is
armed and unmet. It names the condition and sends you back to work. It lets
the session stop when:

- the goal is met or cleared;
- its deadline passes (24 hours by default, at most 7 days);
- it has forced 200 continuations;
- a background task or a session cron (CronCreate, ScheduleWakeup, /loop)
  will wake the session.

## Run it

The arguments are: `$ARGUMENTS`

- **Empty:** run `claude-goal status` and report what it says.
- **`clear`:** run `claude-goal clear "owner cleared"` and confirm.
- **Anything else:** that text is the condition. If it ends with `--hours N`,
  take that off and pass it as `--hours N`. Arm it, passing the condition on
  stdin through a quoted heredoc so no shell expansion touches it:

  ```bash
  claude-goal arm <<'GOAL'
  the condition, verbatim
  GOAL
  ```

  Report what it printed, then start working toward the condition straight
  away. Treat the condition as your directive, and do not stop to ask what to
  do.

## While the goal is armed

- **Done means the condition holds and you checked it.** Get the evidence
  first: the command output, the PR state, the check run. Then run
  `claude-goal met "<that evidence in one line>"`. Never weaken the condition
  to call it met.
- **A plateau is not a dead end.** Change your approach. Run
  `claude-goal clear "<why>"` only at a genuine dead end, such as a missing
  permission or a decision that is the owner's, and say so in the report.
- **Waiting on something external** (CI, a worker, a deploy): do not poll in a
  loop. Arm what will wake you:
  - a background command that exits when the thing happens, or `Monitor`, for
    the event;
  - `CronCreate` as a fallback heartbeat.

  The hook lets the turn end while either is pending. A long-lived background
  process, such as a dev server, also counts as pending, so stop it when you
  no longer need it.
- If the hook's message cuts the condition short, `claude-goal status` shows
  all of it.
- Arm a goal only when the owner asks for one. Never arm one in another
  session.
