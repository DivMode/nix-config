---
name: neon
description: Gemini 4 Neon through the local Antigravity CLI (`agy`) on the owner's Google AI Pro subscription — an independent review of a diff, a second opinion on a plan, or a bounded task Claude delegates and then verifies. Use when the user names Neon ("have Neon review this diff", "ask Neon for an independent opinion on this plan", "delegate this to Neon").
---

# Gemini 4 Neon through agy

Claude stays the coordinator. Neon is a worker whose output is evidence for Claude to assess,
never a verdict to relay or accept unread.

Every call goes through the agy plugin's wrapper with the model named explicitly:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" ask --model <model-id> "<prompt>" <agy flags>
```

- Model ids, as `agy models` lists them for this account (verified 2026-11-23):
  `gemini-4-neon-high` by default, `gemini-4-neon-xhigh` for hard reviews and debugging,
  `gemini-4-neon-medium` for quick questions. Never omit `--model`: agy would fall back to
  whatever its TUI last selected. An unlisted id fails with exit 1 and a model list rather than
  substituting another model; report that, do not swap models.
- Sign-in is the owner's Google account (keychain), not an API key. Never set `GEMINI_API_KEY`,
  `AGY_ADC_AUTH` or Cloud credentials for these calls; that would move usage onto metered billing.
- Always add `--output-format json --print-timeout <limit>`. The result is one JSON object:
  `status` is `SUCCESS` or `ERROR`, `error` carries quota, model-access and sign-in failures,
  `response` is Neon's answer, `conversation_id` resumes it with `--conversation <id>`.
  The wrapper's exit status is agy's. Surface an `ERROR` verbatim with its kind (quota, model
  access, sign-in, timeout); do not retry blindly.
- Run from the intended repository root (`git rev-parse --show-toplevel`), with stdin closed
  (`</dev/null`). Never pass `--dangerously-skip-permissions`.
- Longer than ~8 minutes: run the Bash call with `run_in_background: true`, redirect stdout to a
  file in the session scratchpad, and read it when the completion notification arrives.
- Usage: `agy -p /quota` prints the subscription's remaining Gemini percentages. They are rounded,
  so before/after readings do not measure one call's cost.

## Review or second opinion (read-only, enforced)

Pass the deny rules beside this file, which agy enforces for the session: file writes and shell
commands are refused, reads stay allowed. An instruction saying "read only" is not enforcement.

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" ask --model gemini-4-neon-high "<prompt>" \
  --settings "${CLAUDE_PLUGIN_ROOT}/skills/neon/review-settings.json" \
  --output-format json --print-timeout 20m </dev/null
```

Put the material in the prompt so Neon forms its own view: the original requirement or acceptance
criteria, the full diff (`git diff <base>...HEAD` plus uncommitted changes) or the plan text, and
the files it may read for context. Do not include Claude's own conclusions or suspected findings.
Ask for findings tied to real call paths, each with file, line, the input that triggers it, and
the observed consequence.

Then assess every finding against the code yourself: confirm it, reject it with the reason, or mark
it unverified. Report which Neon findings you accepted and why. Afterwards `git status` must show
the tree exactly as before the call.

## Delegated task

For a bounded implementation or investigation Neon should carry out itself:

1. Create a git worktree on its own branch for the task; never point Neon at the main checkout.
2. Brief it like a peer: goal, acceptance criteria, files in scope, checks to run, and that it
   must not commit or push.
3. Run without the review settings, in agy's default mode (edits inside the workspace,
   sandboxed commands), with a longer limit:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" ask --model gemini-4-neon-high "<brief>" \
     --output-format json --print-timeout 60m </dev/null
   ```

4. Verify the work yourself: read the real diff in the worktree, run the checks, compare against
   the acceptance criteria. Neon's own account of its work is not a review. Then commit, fix, or
   discard it as the coordinator.
