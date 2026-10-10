# Assignment template

The brief a delegated worker receives, shared by the `delegate` (Codex) and `opus-delegate`
(Claude sub-agent) skills. Fill every section; a section left empty or vague means the assignment is
not ready to send. Point at source with paths and symbols rather than pasting whole files, long
logs, or the conversation.

The worker knows only what the assignment says. Copy every repository rule it depends on (worktree
mechanism, test runner, forbidden commands) into IMPLEMENTATION DECISIONS, NON-GOALS, or
VERIFICATION.

```markdown
# Assignment: <one-line objective>

## OBJECTIVE
<One concrete feature or behavior.>

## ACCEPTANCE CRITERIA
<Observable requirements that show the feature works. Passing tests alone is not sufficient.>

## REPOSITORY AND WORKTREE
<Absolute worktree path, branch, HEAD, and expected starting state. For a worker the tool isolates,
"the worktree you start in", plus the main checkout's absolute path, which is never it.>
Before reading or changing anything, run `pwd` and `git rev-parse --show-toplevel` in the
worktree (`cd` to its absolute path first if you did not start there). Both must print the worktree
path; if they do not, stop and report both outputs. Your shell may not stay in the worktree between
commands, so name it by absolute path in every command (`git -C <path>`, absolute file arguments,
`env -C <path>` for tools that act on the current directory). Report the path, and the HEAD from
before you changed anything, in your handoff.

## ALLOWED WRITE SCOPE
<Files or narrow paths you may change. Nothing else.>

## IMPLEMENTATION DECISIONS
<Interfaces, patterns, and components to reuse; decisions already made.>

## NON-GOALS
<What must not change; tempting additions that are out of scope.>

## VERIFICATION
<Commands or evidence required for acceptance.>

## ESCALATION
<Missing decisions or obstacles that mean: stop and report instead of choosing.>

## RULES
- Implement the requested behavior first; optional polish only if the assignment asks.
- Reuse the existing patterns named above. No unrelated refactoring or cleanup.
- No new dependencies unless authorized above.
- No speculative compatibility layers, generic frameworks, retry systems, fallbacks, or config
  options.
- Keep required security, authorization, validation, and data-integrity behavior. Simple does not
  mean removing safeguards.
- Add tests only for the requested behavior and its material failure risks.
- Never weaken assertions, skip checks, or replace real behavior with mocks to get a pass.
- Never change orchestration policy, sandbox, hooks, or permissions to unblock yourself.
- Do not spawn sub-agents. Do not commit, push, open pull requests, ship, deploy, or change cluster
  or cloud state. Leave your changes uncommitted. Do not touch files outside ALLOWED WRITE SCOPE.
- Never run `sh -c`, `bash -c`, `zsh -c` or `eval` with a script string, and never put `rm` inside
  heredocs or command substitutions: each puts a permission prompt in front of the owner, who must
  never see one. Write a multi-step script to a file and run it with `bash <file>`.
- When a required decision is missing, stop and report it rather than expanding the work.
- Stop when the acceptance criteria are met.

## HANDOFF
End with exactly these headings: Status, Summary, Files Changed, Claims / Findings,
Commands Reported, Caveats / Blockers. Under them give the worktree path and starting HEAD, changed
files, acceptance evidence, checks actually run with their results, deviations from this
assignment, remaining gaps, and blockers.
```
