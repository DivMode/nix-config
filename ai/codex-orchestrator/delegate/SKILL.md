---
name: delegate
description: Codex workers — hand a coding job to a Codex CLI worker (gpt-6.1-sol at an effort Claude chooses per job; Fast tier only when the user asks for fast mode) while Claude plans, splits it into parallel pieces, supervises, and accepts. Use when the user names Codex for doing work ("use Codex", "have Codex do it", "Codex fast mode"). Delegation the user has not given to Codex goes through opus-delegate.
---

# Delegate an implementation to Codex

Local policy layered onto codex-orchestrator by nix-config. It narrows the plugin's `workflow` and
`orchestrate` skills; where they differ, this skill wins. The run layout, journal records, runner,
monitoring, and handoff format are upstream's. Before the first dispatch in a session, read
`${CLAUDE_PLUGIN_ROOT}/skills/orchestrate/SKILL.md`,
`${CLAUDE_PLUGIN_ROOT}/skills/orchestrate/references/monitoring.md`, and
`${CLAUDE_PLUGIN_ROOT}/docs/orchestration-contract.md`.

Repository rules outrank this skill on their own ground. Codex reads a repository's `AGENTS.md`
itself but not `CLAUDE.md`, so the assignment carries every rule it depends on. A repository that
needs different delegation defaults (timeout, checks) states them in its own instruction file.

Run records live outside every repository, at `$HOME/.claude/codex-runs/<repo-name>/<run-id>/`,
in upstream's layout (`journal.jsonl`, `<agent>/execution-NN/{prompt.md,events.jsonl,handoff.md}`).
This replaces upstream's `<repo>/.codex-orchestrator/runs/` for three reasons: a repository's
hooks may forbid writes in its main checkout (the work monorepo's do), worktree cleanup would delete
records kept inside a worktree, and they stay out of the worker's own working tree. Skip
upstream's `info/exclude` step, which only exists to hide the in-repo directory; still record the
repository baseline in `run_started` as upstream describes.

## Codex or Claude: decide per piece of work

Upstream says to prefer Codex as the first mover for bounded coding tasks. Here Codex runs only when
the user has named it (global Roles); other delegation goes through `opus-delegate`. Even then,
Codex gets only work where delegating saves Claude more than writing and checking the assignment
costs. Decide for each piece, even inside a project the user said to "use Codex" for.

Send to Codex when all of these hold:
- The decisions are made. What remains is execution, not product, architecture, or design choices.
- It is implementation-heavy: many files, the same transformation repeated across a codebase, or
  a long edit-test-fix loop. As a rough guide, more than about 5 files or 150 changed lines.
- It can be checked by commands, run by Codex or by Claude afterwards.

Do it in Claude directly when any of these hold:
- It is a small fix: a few files, roughly under 50 lines, or the exact edit is already known.
  Writing and verifying the assignment would cost as much as doing it.
- It still needs investigation, debugging of a live system, or a decision.
- It needs cloud access, credentials, deploys, or production data. Codex has network access for
  builds and package downloads, but secrets and anything that changes live systems stay with
  Claude.

If the user explicitly asks for Codex on a specific change, use Codex for it. When a large job
contains small follow-ups, such as a one-line fix after review, do those in Claude rather than
starting another Codex execution. Say in one line which way each piece went and why.

## Who owns what

Claude: understanding the feature actually requested, inspecting the code, resolving product and
architecture decisions, writing acceptance criteria and boundaries, dispatching, reviewing the real
diff, and accepting or rejecting. Codex: implementing the assigned behavior inside those
boundaries, running the named checks, and reporting evidence and blockers accurately. Codex never
widens product scope, introduces architecture, or decides unrelated improvements belong in the task.

## Defaults that narrow upstream

- Split a big job into independent pieces yourself and run them together. There is no fixed cap on
  concurrent Codex jobs (the user's choice, 2026-10-06, replacing the 2026-10-03 cap of 4): run as
  many as there are genuinely independent pieces. See "Running several jobs at once" below.
- No `planning` or `planning_review` agents. No Codex reviewer unless material risk or a specific
  unresolved question justifies one; say which.
- For each piece: one implementation execution, then Claude's verification. At most one targeted correction, by
  resuming the same session. If it still fails, stop and bring the unresolved issue back for a fresh
  decision. Never loop.
- Do not run `config init` or create `.codex-orchestrator/config.ini`: its generated policy is
  `gpt-5.6-sol`, Fast tier, and `xhigh`+. Worker settings are the explicit flags below.
- No `report.md` unless asked. Close a run with `local/codex-journal close`, which validates and
  appends `run_closed`.

## Worker settings

Model: always `-m gpt-6.1-sol`. If Codex rejects it, stop and report it; never substitute another.

Effort: Claude chooses it for each job, as `-c model_reasoning_effort="<effort>"`. The user does not
pick it (2026-10-03). Choose the lowest level the piece needs, because higher levels are slower and
use more of the Codex allowance:

- `medium`: fully specified mechanical edits, such as renames, moves, or one known pattern applied
  repeatedly.
- `high`: the default for a normal bounded implementation with clear acceptance criteria.
- `xhigh`: subtle logic, concurrency, tricky types, a change that cuts across the piece, or the
  correction attempt after a failed execution.
- `max`: rare; only when a wrong answer is expensive and the reasoning is genuinely hard.
- Never `low` for implementation. Never `ultra`: it adds automatic task delegation, which starts
  Codex helper agents in the same worktree.

Record the chosen effort and a one-line reason in the `execution` entry, and say it in the
one-line announcement for each piece. Choose again for a resume rather than copying the previous
value. Confirm once per session that the model offers the level you chose:

```bash
codex debug models | jq -e --arg e "<effort>" '.models[] | select(.slug=="gpt-6.1-sol") | .supported_reasoning_levels[].effort | select(.==$e)'
```

Speed: standard by default. Add `-c service_tier="fast"` to dispatch and resume only when the user
asks for fast mode ("use fast mode", "run Codex fast"). Keep it on for the rest of the session
until they say otherwise. Fast is about 2x faster at roughly 2x the Codex usage; it was measured
working in `codex exec` 0.159.2 at 14.5–15 tok/s standard versus 29–30 tok/s fast on the same
prompt. Do not judge it from the server's `service_tier` field: `response.completed` reports
"default" either way, and rollouts do not record the tier. Authentication comes from the user's
Codex login unchanged.

## Before dispatch

1. Establish the repository root from the checkout (`pwd`, `git rev-parse --show-toplevel`).
2. Create a worktree for the worker with the repository's own mechanism when it has one, otherwise
   `git worktree add`. Never let a worker write in the user's main checkout.
3. Create the run under `$HOME/.claude/codex-runs/` with the journal helper; it captures the
   repository baseline and Codex version. Record the task and repeat `--file` and `--acceptance`
   for each allowed path and criterion. Only one writer may journal a run directory at a time;
   each record atomically replaces the journal while preserving all existing bytes:

   ```bash
   JOURNAL="${CLAUDE_PLUGIN_ROOT}/local/codex-journal"
   "$JOURNAL" start --run-dir "$RUN_DIR" --run-id "$RUN_ID" --repo "$REPO" --goal "<run goal>"
   "$JOURNAL" task --run-dir "$RUN_DIR" --id task-01 --status active --goal "<task goal>" \
     --acceptance "<criterion>" --file "<allowed path>"
   ```
4. Take the scope baseline after the worktree is ready and before launch, and record it as
   `baseline_tree` in the `execution` entry:

   ```bash
   BASE_TREE="$("${CLAUDE_PLUGIN_ROOT}/local/codex-scope" snapshot "$WORKTREE")"
   ```

5. Write `prompt.md` from [assignment.md](assignment.md), the worker brief `opus-delegate` uses
   too. Every launch attempt gets a new `execution-NN` directory: the runner creates
   `events.jsonl` exclusively and refuses one that exists (`could not create events file …
   File exists`), so a relaunch after a failed start is the next number, never a reuse. Before
   launch, append the execution (the helper captures worktree HEAD and branch); add
   `--service-tier fast` only when Fast is on:

   ```bash
   "$JOURNAL" execution --run-dir "$RUN_DIR" --agent codex-impl-01 --execution execution-01 \
     --task task-01 --role implementation --model gpt-6.1-sol --effort "<effort>" \
     --effort-reason "<one-line reason>" --worktree "$WORKTREE" --baseline-tree "$BASE_TREE" \
     --prompt "$EXECUTION_DIR/prompt.md" --events "$EXECUTION_DIR/events.jsonl" \
     --handoff "$EXECUTION_DIR/handoff.md"
   ```

## Dispatch

Launch under upstream's Background Launch Invariant: the Bash tool with `run_in_background: true`
and `description` set to the agent name. `gtimeout --foreground` sends SIGTERM to the runner only;
the runner then stops Codex's process group itself. Pick a finite limit for the task; 45m is the
default.

```bash
RUN_DIR="$HOME/.claude/codex-runs/<repo-name>/<run-id>"
EXECUTION_DIR="$RUN_DIR/codex-impl-01/execution-01"
gtimeout --foreground --signal=TERM --kill-after=60s 45m \
  python3 "${CLAUDE_PLUGIN_ROOT}/scripts/codex_orch_tools.py" run \
    --label codex-impl-01 --repo "$REPO" --role implementation \
    --events "$EXECUTION_DIR/events.jsonl" --prompt "$EXECUTION_DIR/prompt.md" \
  -- codex exec --json --output-last-message "$EXECUTION_DIR/handoff.md" \
     -m gpt-6.1-sol -c model_reasoning_effort="<effort>" -c agents.max_threads=1 \
     -s danger-full-access -c approval_policy=never \
     --dangerously-bypass-hook-trust \
     -c "hooks.PreToolUse=[{matcher=\"Bash\", hooks=[{type=\"command\", command=\"${CLAUDE_PLUGIN_ROOT}/local/codex-guard\"}]}]" \
     -C "$WORKTREE" -
```

The `hooks.PreToolUse` line attaches the guard to this job only. Before they run, it refuses git
commands that commit or push (commit, push, merge, rebase, cherry-pick, revert, am),
`just pr`/`just ship`, GitHub PR, release, and API writes, and deploy and cluster-write commands.
Reads such as `gh pr view`, `git stash push`, and `rg` searches stay allowed. `--dangerously-bypass-hook-trust` lets an inline hook run without Codex's one-time
review. It also runs any hooks the repository ships in `.codex/` without that review, which in
practice means the repository's own guardrails apply to Codex too.

After each execution, append its result. The helper reads `session_id` from the recorded events
path's `thread.started` event and carries forward the task and handoff paths. Repeat
`--changed-file` and `--caveat` as needed. The status vocabulary is fixed: an execution result is
`complete`, `blocked`, or `failed`, a task also takes `pending` and `active`, and validation rejects
anything else (`accepted`, `needs_correction`). Your verdict on the work goes in `verify` records
and `close --judgment`, never in a status:

```bash
"$JOURNAL" result --run-dir "$RUN_DIR" --agent codex-impl-01 --execution execution-01 \
  --status complete --summary "<observed outcome>" --changed-file "<path>"
```

## Running several jobs at once

Codex is slow, so a big job finishes fastest as independent pieces running side by side. Do this
by default for any job that splits cleanly; the user should not have to ask.

1. **Split.** Break the job into pieces that touch disjoint files and do not need each other's
   results. A piece that needs another piece's code waits until that piece is accepted. Size each
   piece to finish well inside Codex's context. `gpt-6.1-sol` has a 272k-token window (catalog,
   2026-10-03), compacted at about 95%, and Codex's own instructions use part of it. A piece that
   needs most of a package read, or dozens of files changed, is too big; split it again. Pieces
   that are small fixes stay with Claude, per the routing rule above.
2. **Scale.** No fixed cap on concurrent jobs or on how many of them run heavy work (Rust builds,
   test suites, bundlers): the machine has 96 GB of memory and Codex usage is effectively
   unlimited (the user, 2026-10-06). The number of pieces is set by how the work splits, not by a
   quota; do not split work that is not independent just to run more jobs. If memory pressure
   actually appears (`memory_pressure`, swap growth), hold new heavy jobs until it clears. A
   repository's own instructions may set a tighter limit for its own reasons. Parallel Rust pieces
   need separate cargo target dirs, which some repositories' worktree recipes create per worktree.
   Without separate dirs they queue on cargo's build lock.
3. **Isolate.** Give each piece its own worktree from the repository's mechanism, its own agent name
   in the same run (`codex-impl-01`, `codex-impl-02`, …), its own task and `files`, its own scope
   baseline, and its own background task. The one-correction limit applies per piece.
4. **Announce.** Before launching, tell the user in one line per piece what it does, which files it
   owns, and the effort chosen with its reason.
5. **Collect.** Verify each piece as it finishes, exactly as in Accept; a blocked piece does not stop
   the others. Integrate each accepted piece through the repository's workflow as its own slice.
   When pieces must ship together, combine them in one worktree after review and rerun the checks
   there.

## Observe, resume, cancel

- Progress: the background task in `/tasks`, and upstream's `state` command. Use `monitor --log
  "$EXECUTION_DIR/events.jsonl"`; its `--repo --run-id` form looks inside the repository. Keep raw
  `events.jsonl` out of context unless diagnosing a specific failure.
- Close: `"$JOURNAL" close --run-dir "$RUN_DIR" --judgment passed --summary "<acceptance summary>"`.
  Use `blocked` when unresolved; repeat `--risk` and `--follow-up` for remaining items. It appends
  terminal updates for open tasks (`complete` for passed, `blocked` for blocked), preserves existing
  terminal states, validates, appends `run_closed` with that output, and validates again. A validation
  failure is reported and earlier records are never rewritten. `run_closed` requires `judgment`
  (`passed` or `blocked`) and `validation`, the pre-close validation output; `close` writes both.
  Every record's fields are in `${CLAUDE_PLUGIN_ROOT}/docs/orchestration-contract.md`.
- Correction: the one allowed correction resumes the same session as the next `execution-NN` under
  the same agent, with its own `prompt.md`, `execution` entry, and scope baseline. Choose its effort
  again; a correction after a failure usually warrants `xhigh`. Add `-c service_tier="fast"` only
  when Fast is on, and never use `--last`. `codex exec resume` rejects `-s` and `-C` (`error:
  unexpected argument '-s' found`), and upstream's resume example in `monitoring.md` does not carry
  the guard, so use this one: the sandbox goes in as `-c`, and `env -C` makes the worktree its
  working directory, and `SESSION_ID` comes from the previous execution's `thread.started` event.
  Verified on codex-cli 0.160.1 (2026-10-09): the resumed turn's rollout
  recorded the worktree as `cwd` and `danger-full-access` as its sandbox.

  ```bash
  SESSION_ID="$(jq -r 'select(.type=="thread.started").thread_id' "$RUN_DIR/codex-impl-01/execution-01/events.jsonl")"
  EXECUTION_DIR="$RUN_DIR/codex-impl-01/execution-02"
  gtimeout --foreground --signal=TERM --kill-after=60s 45m \
    env -C "$WORKTREE" python3 "${CLAUDE_PLUGIN_ROOT}/scripts/codex_orch_tools.py" run \
      --label codex-impl-01 --repo "$REPO" --role implementation \
      --events "$EXECUTION_DIR/events.jsonl" --prompt "$EXECUTION_DIR/prompt.md" \
    -- codex exec resume --json --output-last-message "$EXECUTION_DIR/handoff.md" \
       -m gpt-6.1-sol -c model_reasoning_effort="<effort>" -c agents.max_threads=1 \
       -c 'sandbox_mode="danger-full-access"' -c approval_policy=never \
       --dangerously-bypass-hook-trust \
       -c "hooks.PreToolUse=[{matcher=\"Bash\", hooks=[{type=\"command\", command=\"${CLAUDE_PLUGIN_ROOT}/local/codex-guard\"}]}]" \
       "$SESSION_ID" -
  ```
- Cancel: stop the background task. The runner exits 143 after stopping Codex. A timeout exits 124.
- A timeout stops Codex but not the command Codex was running: its shell commands run in their
  own process group, and a `sleep` outlived a timeout as an orphan (observed 2026-10-03; stopping
  the task did reap it). After any cancel or timeout, list what still runs in the worktree and stop
  it before inspecting anything:

  ```bash
  lsof -d cwd -Fpn 2>/dev/null | awk -v w="$WORKTREE" '/^p/{p=substr($0,2)} /^n/ {d=substr($0,2); if (d==w || index(d, w "/")==1) print p}'
  ```

  This matches the worktree and its subdirectories only, never a sibling worktree whose name
  starts the same way. A leftover whose working directory is elsewhere is not listed, so check
  the process list as well if a command was running when the job stopped.

- After a cancel, timeout, or failure, keep the worktree exactly as it is. Do not reset, discard,
  or accept. Run the scope check, use `"$JOURNAL" result` with `--status blocked` or `failed` and what
  exists, and report the state.

## Accept

1. Read the handoff as claims, not evidence.
2. Compare changed paths with the assignment. Exit 1 lists out-of-scope paths; account for every
   one before going further:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/local/codex-scope" check "$WORKTREE" "$BASE_TREE" -- <allowed pathspecs>
   ```

3. Confirm `git -C "$WORKTREE" rev-parse HEAD` still equals the recorded `head`.
4. Read the actual diff. Evaluate every acceptance criterion by observation, and run the
   verification commands yourself. Record each with the helper (`--result` is `passed`, `failed`,
   `inconclusive`, or `skipped`; repeat optional `--evidence` for files):

   ```bash
   "$JOURNAL" verify --run-dir "$RUN_DIR" --id check-01 --task task-01 \
     --criterion "<criterion>" --method command --check "<exact command>" \
     --result passed --observation "<what you observed>"
   "$JOURNAL" task --run-dir "$RUN_DIR" --id task-01 --status complete
   ```
5. Integrate through the repository's own workflow. The worker's changes are uncommitted edits in
   the worktree, and the handoff says what it did. The worker never commits or ships.

## What actually constrains the worker

- No sandbox. The user chose `danger-full-access` on 2026-10-03, matching their everyday Codex
  config. `workspace-write` blocked Rust: crate downloads need the network, and cargo writes to the
  shared cargo home outside the worktree. Codex can therefore write anywhere the user can and use
  the network. `approval_policy=never` means it is never stopped to ask. `agents.max_threads=1` caps
  sub-agents at one concurrent child; Codex 0.159.2 offers no setting verified to remove them.
- Enforced by the guard hook (`local/codex-guard`, a Codex PreToolUse hook passed on the command
  line): committing and pushing git commands, ship, GitHub PR, release, and API writes, deploy, and
  cluster-write commands are rejected before they run. It reads each tool's real subcommand, so it
  catches them behind `git -C`/`-c`, `bash -c '...'`, `env`, `$(...)`, redirections, and full
  paths, while reads such as `gh pr view` or `git stash push` run. It stops ordinary mistakes, not
  a determined bypass: a Python one-liner or a script that runs them internally gets through. A
  command typed into an already-open interactive shell may not pass through the hook at all; that
  is a hypothesis, untested. A `codex-guard-canary` command is always refused, which proves the
  hook is loaded.
- Enforced by the launcher: the `gtimeout` limit, for Codex itself. Commands Codex started can
  outlive it; see the orphan check above.
- Detected after the run: `codex-scope` (content changes outside scope, including untracked,
  staged, and unstaged), HEAD movement, and Claude's diff review.
- Prompt instructions only: everything under RULES, including no sub-agents.
- Not covered: anything outside the worktree (other repositories, the main checkout, home
  directory files, network actions other than the blocked commands), ignored files, and temp
  dirs. `codex-scope` sees only the worktree, so the RULES against those are prompt
  instructions, not enforcement.
