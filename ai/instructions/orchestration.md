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

**Remote workers do not read either file** — they are files on this Mac, and
a cloud or browser session cannot see them. Do not assume a remote participant
has read this policy. Supply relevant canonical policy excerpts and acceptance
criteria with remote tasks, including review tasks; a link alone is not proof
that the recipient received or read them.

## Roles

- **Claude Code** is the coordinator: the session the user works with plans,
  delegates, verifies, and **merges verified work** for changes the user asked
  for, rather than leaving a finished pull request open. Ask first only when
  the repository requires another reviewer or the merge is hard to reverse.
  Claude Code is also the default implementation and review worker.
- **Workers** are Claude sub-agents (the `opus-delegate` skill) and Codex (the
  `delegate` skill), dispatched and supervised by the coordinator.
  **The user's most recent instruction picks the worker:** "Codex" means
  `delegate`; "Opus", "sub-agents", or no instruction means `opus-delegate`.
- **GitHub** is the durable source of truth. Issues, pull requests, and commits
  outlive every session.

## Binding rules

1. **Use the current client's native tools.** Carry out work in the active
   coding client. Use its own delegation and status tools when another worker
   is warranted. Do not make the person relay prompts between agent windows.

2. **List, then reuse, then create.** Before opening a worker, list the
   existing sessions and look for one that already owns this task or issue.
   Reattach to it. Two workers on one task produce two divergent answers and
   one merge conflict. Name sessions after the task or issue they own, and open
   them with the correct project working directory.

3. **Protect personal terminal sessions.** Do not modify, reset, or close
   personal Herdr workspaces, panes, or tabs unless explicitly asked to.

4. **A long turn is not a stuck turn.** `status: running` is the normal state
   for real work. Follow the same worker using the current client's status tools
   and the continuation cursor when one is available. Never resend the task
   because a soft wait expired or a prompt-stalled signal appeared — that
   signal is a heuristic, it is wrong often enough to matter, and a resend
   duplicates work already in flight. Do not hammer output reads; rely on the
   reported working/idle state and space the polls out.

5. **Interrupting the coordinator does not stop the workers.** A new user message
   interrupts the conversation you are having; it does not cancel a worker
   that is mid-turn, and it must not be read as an instruction to kill,
   restart, or replace one. After any interruption, redirection, or context
   loss, the first move is to **re-list the sessions and resume polling the
   same named worker** from where it was. Stop or replace a worker only when
   the user explicitly asks for that, or when they have changed the task that
   worker owns. If you genuinely cannot tell whether in-flight work is still
   wanted, say what is running and ask — do not silently abandon it and do not
   silently start a second one.

6. **Reconcile before you open.** At the start of substantial work and after
   an interruption, inspect the current client's worker status and any pending
   results. Events are history; the current worker status is the liveness
   authority. Resume the worker that owns the task before creating another.
   After resumption or context loss, re-read the applicable instructions and
   durable acceptance criteria; do not restart implementation from a summary.

7. **Model routing for Claude workers.** **A worker never runs the
   coordinator's model.** Each worker gets its own model and its own effort,
   chosen for its task from the table in the `opus-delegate` skill. The `opus`
   alias resolves to an Opus coordinator's own model, so an Opus coordinator
   never passes it. Read the model a worker actually ran from its transcript
   rather than assuming it. Raise effort, not the model, when a piece is hard.
   **Never use Fable unless
   the user explicitly asks for Fable by name.** It is opt-in only and is never
   an automatic or default choice.

8. **Implementation and review stay separate** for anything significant or
   risky, whenever that is practical. A worker's own account of its work is not
   an independent review, and it must not be the only one. Give the reviewer
   the diff and the original requirement, not the implementer's summary.
   **Implementation workers do not self-approve**: a delegated worker hands its
   evidence to the coordinator, which reviews it and decides what merges.
   **Review necessity before correctness.** For each new test group or support
   subsystem, check the required behavior, distinct failure it detects, and
   cheaper existing alternative. Reject unjustified additions even when all
   tests pass. Inspect the original requirement, actual diff, and execution
   evidence; a clean automated review is not proof of necessity or completion.

9. **A separate Claude reviewer is optional, not mandatory.** Open one when
   risk, complexity, or local execution earns a genuinely independent read —
   security, protocol and MCP behaviour, Nix and system state, migrations,
   concurrency and shared state, large refactors. Its verdict is **evidence for
   the coordinator, not a substitute for its review and merge decision**.
   Skip it for small, low-risk, plainly correct work, and say you skipped it.

10. **Never open a Claude session solely to watch another one.** Routine
    progress comes from the current client's status and wait tools for the
    worker that owns the work, and the coordinator reconciling its results — a
    monitoring worker costs a model, learns nothing the cursor does not already
    carry, and invites the duplicate ownership rule 2 exists to prevent. A
    short-lived read-only health probe is exceptional, justified only when the
    semantic state itself looks inconsistent or stuck, and is
    **closed immediately afterwards**.
    **Never message an idle session whose prompt cache has gone cold**: it
    re-reads its whole context uncached. Record it on GitHub or brief a fresh agent.

11. **Checkpoint durably.** Read the relevant issue, pull request, and its
    latest comments before acting — they usually already contain the decision
    you were about to re-derive. Record outcomes back there, commit and push
    completed work, and never leave an important finding only in a terminal
    transcript that closes with the session. Preserve unrelated worktrees and
    files. Never commit secrets or private local state. Exception: a delegated
    worker, Claude sub-agent or Codex job, leaves its changes uncommitted, and
    its coordinator reviews, commits, and pushes them.

12. **This machine is declarative.** Environment, settings, and configuration
    changes belong in the Nix configuration repository — Home Manager or
    nix-darwin — not in ad-hoc shell edits, hand-written dotfiles, or GUI
    clicks. The exception is an unavoidable emergency the user has explicitly
    approved, and it is followed by codifying the change. After a declarative
    change, rebuild and verify through the repository's own scripts rather than
    assembling an activation command by hand.

13. **Work in the intended checkout.** Confirm the repository root from the
    checkout itself before reading or changing anything, and never let a
    convenient copy of a repository become a second source of truth. If you
    find two checkouts of the same project, say so and ask which is canonical
    rather than picking one.

14. **No hidden fleets.** The active coordinator owns orchestration. A
    worker may use its own subagents where they clearly help — genuine
    breadth, or an independent adversarial read — but must not spawn a nested
    fleet that duplicates ownership of a task another session already holds.
    State which files each concurrent agent owns before they start.

15. **A more specific instruction file wins on its own ground.** A repository's
    `AGENTS.md` or `CLAUDE.md` governs that project's conventions. This policy
    is the machine-level default underneath it, and it still governs anything
    the project file does not speak to. A direct instruction from the user
    outranks both.
