# Failure audit of this machine's agent session history

Research date: 2026-08-13
Method: from `docs/research/2026-08-13-agent-instruction-file-design.md` — derive
rules from what actually went wrong, not from imagination about what might.
Source: 7 session files, 12MB, under the local agent session directory.

## Conclusion

Two findings are worth acting on, and both were invisible without counting.

1. **Roughly two thirds of guard blocks are false positives.** Guards match the
   *text* of a command, not its effect, so they fire on reading about a
   forbidden thing as readily as on doing it. Treating those as violations
   wastes time and, worse, invites asking the user for permission to read
   something.
2. **Every missing tool was found by attempting work, never by a check.** Four
   in one day. Nothing reports "this machine can no longer do X" until
   something tries to do X and fails, often at the worst moment.

## Volume

| | |
| --- | --- |
| Tool calls | 924 |
| Bash | 699 (76%) |
| Edit | 124 |
| Read / Write | 32 / 32 |
| Errored or blocked results | 36 (3.9%) |

Bash dominance is worth noting on its own: three quarters of all actions go
through a shell, which is also the surface every text-matching guard inspects.
That is why guard false positives are the largest single failure category.

## Finding 1: guard blocks are mostly false positives

Sixteen blocks, hand-classified by whether the blocked command would have
changed anything:

| Blocked command | Would it have changed anything? |
| --- | --- |
| `ls` of a directory | no |
| `grep` of a hook's own source | no |
| `git check-ignore -v` | no |
| `git config --get` | no |
| `readlink -f` | no |
| `ls -l` of a config path | no |
| a `grep` whose *pattern* contained a forbidden phrase | no |
| a commit message naming hook-bypass variables, while forbidding them | no |
| a commit message naming a protected config path, while explaining it | no |
| a guard's own test harness feeding it sample payloads | no |
| a compound command whose first clause was unrelated | no |
| creating a worktree with plain git | **yes** |
| appending to a repository's exclude file | **yes** |
| `git pull` on a protected branch | **yes** |
| a PR body under the minimum length | **yes** |
| an edit outside the required worktree | **yes** |

Eleven of sixteen changed nothing. An automated classifier scored this at five
of sixteen, undercounting badly, because a compound command that *contains* a
mutating verb somewhere reads as mutating. The hand count is the honest one, and
the discrepancy is itself a caution about trusting a quick heuristic over
reading the material.

The rule this produced is now in `ai/instructions/global.md`: separate "the
command would not have changed anything" from "the command would have", say
which case it was, and never rephrase in the second case.

Two of the false positives deserve naming because they will recur: **a commit
message that documents a rule against a mechanism trips the guard for that
mechanism**. Writing down why a bypass is forbidden looks exactly like
attempting it.

## Finding 2: missing tools surface only on use

Four tools were absent and each was discovered by work failing:

| Tool | How it surfaced |
| --- | --- |
| `bun` | a worktree helper died with "command not found" |
| `flock` | a deploy reported a two-hour lock timeout; the real error was on the next line |
| Playwright browsers | a post-deploy smoke gate failed *after* the deploy went out |
| `yt-dlp` | no way to read a transcript |

The `flock` case is the instructive one: the failure message was actively
misleading, blaming a lock nothing held. A missing dependency that surfaces as a
plausible but wrong diagnosis costs far more than one that surfaces as "not
found".

Three of the four were casualties of a machine rebuild — they had only ever been
installed imperatively, so nothing restored them. All four are now declared.

## Finding 3: silent misconfiguration outlives everything

Two configuration faults ran undetected far longer than any transient error:

- A skill's description had not loaded for weeks, because a note was appended
  inside its frontmatter fences. Nothing errored; the skill simply routed on its
  heading, and every trigger phrase in it was inert.
- An untracked settings file had been overriding a sandbox setting for four
  months, written by the client itself when a permission was approved.

Neither would ever appear in an error count. Both were found only by comparing
what a tool *reported* against what a file *said* — the same technique that
resolved the longest debugging session in this history.

## What this suggests doing

- Keep the distinction between blocked-and-harmless and blocked-and-correct
  explicit, in the instructions and in what gets reported back.
- Prefer comparing a tool's own view of its state against the stored state, over
  reasoning about mechanism. It has now caught three separate faults that error
  counts could not.
- When a failure message names a cause, check the line below it before believing
  it.
