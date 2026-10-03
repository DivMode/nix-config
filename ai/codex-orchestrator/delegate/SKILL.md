---
name: delegate
description: Delegate one precisely scoped implementation to a Codex CLI worker (gpt-6.1-sol, high effort) while Claude plans, supervises, and accepts. Use when the user asks to implement something through, with, or by Codex, or to delegate coding work to Codex.
---

# Delegate an implementation to Codex

Local policy layered onto codex-orchestrator by nix-config. It narrows the plugin's `workflow` and
`orchestrate` skills; where they differ, this skill wins. The run layout, journal records, runner,
monitoring, and handoff format are upstream's. Before the first dispatch in a session, read
`${CLAUDE_PLUGIN_ROOT}/skills/orchestrate/SKILL.md`,
`${CLAUDE_PLUGIN_ROOT}/skills/orchestrate/references/monitoring.md`, and
`${CLAUDE_PLUGIN_ROOT}/docs/orchestration-contract.md`.

Repository rules outrank this skill on their own ground. Codex reads a repository's `AGENTS.md`
itself but not `CLAUDE.md`, so copy every repository rule the assignment depends on (worktree
mechanism, test runner, forbidden commands) into its IMPLEMENTATION DECISIONS, NON-GOALS, or
VERIFICATION. A repository that needs different delegation defaults (run directory, timeout,
checks) states them in its own instruction file.

## Who owns what

Claude: understanding the feature actually requested, inspecting the code, resolving product and
architecture decisions, writing acceptance criteria and boundaries, dispatching, reviewing the real
diff, and accepting or rejecting. Codex: implementing the assigned behavior inside those
boundaries, running the named checks, and reporting evidence and blockers accurately. Codex never
widens product scope, introduces architecture, or decides unrelated improvements belong in the task.

## Defaults that narrow upstream

- One writing worker. Run parallel workers only for genuinely independent assignments, each in its
  own worktree with disjoint `files`, and state the ownership before launch.
- No `planning` or `planning_review` agents. No Codex reviewer unless material risk or a specific
  unresolved question justifies one; say which.
- One implementation execution, then Claude's verification. At most one targeted correction, by
  resuming the same session. If it still fails, stop and bring the unresolved issue back for a fresh
  decision. Never loop.
- Do not run `config init` or create `.codex-orchestrator/config.ini`: its generated policy is
  `gpt-5.6-sol`, Fast tier, and `xhigh`+. Worker settings are the explicit flags below.
- No `report.md` unless asked. Close a run with `validate` then `run_closed`.

## Worker settings

`-m gpt-6.1-sol -c model_reasoning_effort="high"`, both read from Codex's own model catalog
(`gpt-6.1-sol` lists `high`). Not `ultra`: that level adds automatic task delegation. If Codex
rejects the model or effort, stop and report it; never substitute another. Confirm once per
session:

```bash
codex debug models | jq -e '.models[] | select(.slug=="gpt-6.1-sol") | .supported_reasoning_levels[].effort | select(.=="high")'
```

The service tier and authentication come from the user's Codex configuration unchanged.

## Before dispatch

1. Establish the repository root from the checkout (`pwd`, `git rev-parse --show-toplevel`).
2. Create a worktree for the worker with the repository's own mechanism when it has one, otherwise
   `git worktree add`. Never let a worker write in the user's main checkout.
3. Initialize the run in the repository root exactly as the upstream workflow's Run
   Initialization describes, and record the task with its allowed `files`.
4. Take the scope baseline after the worktree is ready and before launch, and record it as
   `baseline_tree` in the `execution` entry:

   ```bash
   BASE_TREE="$("${CLAUDE_PLUGIN_ROOT}/local/codex-scope" snapshot "$WORKTREE")"
   ```

5. Write `prompt.md` from the template below. Do not dispatch while any section is empty or vague.
   Point at source with paths and symbols; do not paste whole files, long logs, or this
   conversation.

## Assignment template

```markdown
# Assignment: <one-line objective>

## OBJECTIVE
<One concrete feature or behavior.>

## ACCEPTANCE CRITERIA
<Observable requirements that show the feature works. Passing tests alone is not sufficient.>

## REPOSITORY AND WORKTREE
<Absolute worktree path, branch, HEAD, and expected starting state.>

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
- Never change orchestration policy, sandbox, or permissions to unblock yourself.
- Do not spawn sub-agents. Do not commit, push, or touch files outside ALLOWED WRITE SCOPE.
- When a required decision is missing, stop and report it rather than expanding the work.
- Stop when the acceptance criteria are met.

## HANDOFF
End with exactly these headings: Status, Summary, Files Changed, Claims / Findings,
Commands Reported, Caveats / Blockers. Under them give changed files, acceptance evidence, checks
actually run with their results, deviations from this assignment, remaining gaps, and blockers.
```

## Dispatch

Launch under upstream's Background Launch Invariant: the Bash tool with `run_in_background: true`
and `description` set to the agent name. `gtimeout --foreground` sends SIGTERM to the runner only;
the runner then stops Codex's process group itself. Pick a finite limit for the task; 45m is the
default.

```bash
EXECUTION_DIR="$REPO/.codex-orchestrator/runs/<run-id>/codex-impl-01/execution-01"
gtimeout --foreground --signal=TERM --kill-after=60s 45m \
  python3 "${CLAUDE_PLUGIN_ROOT}/scripts/codex_orch_tools.py" run \
    --label codex-impl-01 --repo "$REPO" --role implementation \
    --events "$EXECUTION_DIR/events.jsonl" --prompt "$EXECUTION_DIR/prompt.md" \
  -- codex exec --json --output-last-message "$EXECUTION_DIR/handoff.md" \
     -m gpt-6.1-sol -c model_reasoning_effort="high" -c agents.max_threads=1 \
     -s workspace-write -c approval_policy=never -C "$WORKTREE" -
```

Record `model` and `effort` as requested values in the `execution` entry. The session id is the
`thread_id` of the stream's `thread.started` event:

```bash
jq -r 'select(.type=="thread.started") | .thread_id' "$EXECUTION_DIR/events.jsonl"
```

## Observe, resume, cancel

- Progress: the background task in `/tasks`, and upstream's `state` / `monitor` commands. Keep raw
  `events.jsonl` out of context unless diagnosing a specific failure.
- Correction: the one allowed correction is upstream's resume command as `execution-02` under the
  same agent, with that session id, the same `-C "$WORKTREE"`, and the same `-m`, effort,
  `agents.max_threads`, sandbox, approval, and `gtimeout` settings. Never `--last`.
- Cancel: stop the background task. The runner exits 143 after stopping Codex. A timeout exits 124.
- A timeout stops Codex but not the command Codex was running: its shell commands run in their
  own process group, and a `sleep` outlived a timeout as an orphan (observed 2026-10-03; stopping
  the task did reap it). After any cancel or timeout, list what still runs in the worktree and stop
  it before inspecting anything:

  ```bash
  lsof -d cwd -Fpn 2>/dev/null | awk -v w="$WORKTREE" '/^p/{p=substr($0,2)} /^n/ && index(substr($0,2), w)==1 {print p}'
  ```

- After a cancel, timeout, or failure, keep the worktree exactly as it is. Do not reset, discard,
  or accept. Run the scope check, record `execution_result` as `blocked` or `failed` with what
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
   verification commands yourself. Record each as `verification`.
5. Integrate through the repository's own workflow. The worker never commits or ships.

## What actually constrains the worker

- Enforced by Codex at runtime: `workspace-write` limits writes to the worktree and temp dirs and
  leaves network off; `approval_policy=never` makes anything needing more fail instead of
  prompting; `agents.max_threads=1` caps sub-agents at one concurrent child (Codex 0.159.2 offers
  no setting verified to remove sub-agents entirely).
- Enforced by the launcher: the `gtimeout` limit, for Codex itself. Commands Codex started can
  outlive it; see the orphan check above.
- Detected after the run: `codex-scope` (content changes outside scope, including untracked,
  staged, and unstaged), HEAD movement, and Claude's diff review.
- Prompt instructions only: everything under RULES, including no sub-agents.
- Not covered: reads anywhere on disk (the sandbox restricts writes, not reads), ignored files,
  writes in temp dirs. A worktree is not a machine-security sandbox.
