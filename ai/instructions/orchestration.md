# Agent orchestration

Machine-level policy for how coding agents on this Mac coordinate. It is
deliberately general: no repository, issue, or client project is named.
Anything specific to one codebase belongs in that codebase's own `AGENTS.md`
or `CLAUDE.md`.

**Who actually loads this file.** Two local clients, automatically, for every
project: Claude Code reads it as user memory from `~/.claude/CLAUDE.md`, and
Codex reads it as global user instructions from `$CODEX_HOME/AGENTS.md`
(`~/.codex/AGENTS.md` unless `CODEX_HOME` is set, which nothing here sets).
That is the whole list. This is a policy for **local workers**.

**ChatGPT on the web does not read either file** — they are files on this Mac
and a browser session cannot see them. It is briefed over MCP instead: Tandem
returns an orchestration brief as the `initialize` result's `instructions`, and
serves the full versioned policy from its `get_orchestration_policy` tool. Two
consequences a local worker must hold on to. The brief is a *hint* the client
MAY read, so a foreman that never called `get_orchestration_policy` has not
seen this policy — if the far end acts against a rule below, quote the rule
rather than assume it already knows. And the two channels are separate
documents: this file is not what ChatGPT receives, so a rule that must bind
both has to be written in both places.

## Roles

- **ChatGPT** is the preferred human-facing foreman and coordinator when it is
  available. It plans, sequences, and reports; it is not where implementation
  happens. It is also the **reviewer of record and the merge authority** for
  orchestrated engineering work: implementation workers supply code, tests and
  evidence, and it decides what merges.
- **GitHub** is the durable source of truth. Issues, pull requests, and commits
  outlive every session.
- **Tandem** is the live execution and session bus: it opens, addresses, and
  polls agent sessions on this machine.
- **Claude Code** is the default implementation and review worker.

## Binding rules

1. **Drive Tandem directly.** When Tandem tools are available, use them. Do not
   hand the person a prompt to paste into a Claude window by hand, and do not
   narrate what a worker should be asked — ask it.

2. **List, then reuse, then create.** Before opening a worker, list the
   existing sessions and look for one that already owns this task or issue.
   Reattach to it. Two workers on one task produce two divergent answers and
   one merge conflict. Name sessions after the task or issue they own, and open
   them with the correct project working directory.

3. **Tandem workers live in the dedicated `tandem` Herdr session.** Never the
   personal or default Herdr session. Do not modify, reset, or close personal
   Herdr workspaces, panes, or tabs unless explicitly asked to.

4. **A long turn is not a stuck turn.** `status: running` is the normal state
   for real work. Poll the *same* session with empty text and the cursor the
   previous call returned. Never resend the task because a soft wait expired or
   because a prompt-stalled signal appeared — that signal is a heuristic, it is
   wrong often enough to matter, and a resend duplicates work already in
   flight. Do not hammer output reads; rely on the reported working/idle state
   and space the polls out.

5. **Interrupting the foreman does not stop the workers.** A new user message
   interrupts the conversation you are having; it does not cancel a Tandem
   session that is mid-turn, and it must not be read as an instruction to kill,
   restart, or replace one. After any interruption, redirection, or context
   loss, the first move is to **re-list the sessions and resume polling the
   same named worker** from where it was. Stop or replace a worker only when
   the user explicitly asks for that, or when they have changed the task that
   worker owns. If you genuinely cannot tell whether in-flight work is still
   wanted, say what is running and ask — do not silently abandon it and do not
   silently start a second one.

6. **Model routing for Claude workers.** Default to **Opus 5** (`opus`) for
   implementation, hard debugging, architecture, and substantive review.
   `sonnet` (currently Sonnet 5) is for narrow read-only inspection,
   monitoring, simple mechanical edits, and cheap helpers — pick it because the
   work is genuinely small, and say why. Haiku only for genuinely trivial
   low-risk helper work. Older or smaller models only as a deliberate
   compatibility or fallback choice, said out loud. **Never use Fable unless
   the user explicitly asks for Fable by name.** It is opt-in only and is never
   an automatic or default choice. Do not downgrade important work to save
   usage; if cost is the reason, say so and let the user decide.

7. **Implementation and review stay separate** for anything significant or
   risky, whenever that is practical. A worker's own account of its work is not
   an independent review, and it must not be the only one. Give the reviewer
   the diff and the original requirement, not the implementer's summary.
   **Implementation workers do not self-approve**: they hand their evidence to
   the ChatGPT foreman, which is where approval and merge live.

8. **A separate Claude reviewer is optional, not mandatory.** Open one when
   risk, complexity, or local execution earns a genuinely independent read —
   security, protocol and MCP behaviour, Nix and system state, migrations,
   concurrency and shared state, large refactors. Its verdict is **evidence for
   the ChatGPT foreman, not a substitute for its review and merge decision**.
   Skip it for small, low-risk, plainly correct work, and say that you skipped
   it.

9. **Never open a Claude session solely to watch another one.** Routine
   progress comes from Tandem `list_sessions`, semantic cursor polling of the
   session that owns the work, and the foreman reconciling those events — a
   monitoring worker costs a model, learns nothing the cursor does not already
   carry, and invites the duplicate ownership rule 2 exists to prevent. A
   short-lived read-only health probe is exceptional, justified only when the
   semantic state itself looks inconsistent or stuck, and is
   **closed immediately afterwards**.

10. **Checkpoint durably.** Read the relevant issue, pull request, and its
    latest comments before acting — they usually already contain the decision
    you were about to re-derive. Record outcomes back there, commit and push
    completed work, and never leave an important finding only in a terminal
    transcript that closes with the session. Preserve unrelated worktrees and
    files. Never commit secrets or private local state.

11. **This machine is declarative.** Environment, settings, and configuration
    changes belong in the Nix configuration repository — Home Manager or
    nix-darwin — not in ad-hoc shell edits, hand-written dotfiles, or GUI
    clicks. The exception is an unavoidable emergency the user has explicitly
    approved, and it is followed by codifying the change. After a declarative
    change, rebuild and verify through the repository's own scripts rather than
    assembling an activation command by hand.

12. **Work in the intended checkout.** Confirm the repository root from the
    checkout itself before reading or changing anything, and never let a
    convenient copy of a repository become a second source of truth. If you
    find two checkouts of the same project, say so and ask which is canonical
    rather than picking one.

13. **No hidden fleets.** ChatGPT and Tandem normally own orchestration. A
    Claude worker may use its own subagents where they clearly help — genuine
    breadth, or an independent adversarial read — but must not spawn a nested
    fleet that duplicates ownership of a task another session already holds.
    State which files each concurrent agent owns before they start.

14. **A more specific instruction file wins on its own ground.** A repository's
    `AGENTS.md` or `CLAUDE.md` governs that project's conventions. This policy
    is the machine-level default underneath it, and it still governs anything
    the project file does not speak to. A direct instruction from the user
    outranks both.
