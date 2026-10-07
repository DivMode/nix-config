---
name: wrap-up
description: Close out a piece of work in one pass. Confirm it shipped, then review the product, the agent environment and the code architecture, and file what the user accepts.
disable-model-invocation: true
argument-hint: "Which work to wrap up (default: this session's)"
---

# Wrap-up

Run this at the end of a piece of work. One pass covers everything; the user runs nothing else.

The work is the session's changes, or whatever the arguments name. Work from evidence: PRs, deploy output, logs, live endpoints, the session's own transcript. Every finding carries the observation behind it, and anything unproven is labelled a hypothesis.

## 1. Confirm the outcome

For each change in scope, establish where it actually stands:

- **merged:** the PR is merged;
- **deployed:** the running system includes it;
- **observed:** the behaviour it was for was seen working in the real system, not only in tests.

Check each yourself, through the system's own endpoints, logs or deploy plan. Close any gap you can close now, then record what remains, with the reason.

Done when every change has all three states marked, each with evidence.

## 2. Review three lenses

Go through every category in all three lenses. A category is either answered with findings or explicitly found clear.

### Product: what could fail silently, and what did we assume but never verify?

- **Detection:** if this broke tomorrow, who would notice, and how? A failure that only the user would spot is a finding.
- **Correctness:** outputs never checked against an independent source, and design assumptions written down as unverified in ADRs or comments.
- **Two sources of truth:** the same fact (a limit, a budget, a config value) tracked in two places that can disagree.
- **Local-only state:** unpushed branches, uncommitted files, temp-dir documents, and session-only scheduled jobs that die with the session.
- **Loose ends:** issues and PRs this work touched that are stale, done but still open, or blocked on someone.

### Agent environment: what would make the next run faster and safer?

Load the `writing-for-agents` skill before proposing any change to instructions or skills.

- **Guardrails:** read the repository's own check commands and CI first.
  - Each mistake this session made that an automated check (lint, types, tests, a hook) would have caught is a finding.
  - For each such mistake, and each one this session was asked to fix, check that the guard covers every way to perform the same action, not only the spelling that occurred.
  - So is a check that exists but doesn't run automatically.
  - So is a repository with no CI or pre-commit guardrail at all.
  - A mechanical rule gets a deterministic check rather than written guidance.
- **Navigation:** information that took the session long to find, where a short pointer in the repository's docs or instruction file would have led straight to it.
- **Information access:** evidence the session needed but couldn't reach (logs, history, read access to a service), or could only reach through a workaround.
- **Tool economy:** expensive or repeated tool calls that a script or a better command would replace.
- **Toil:** a multi-step manual procedure this session ran that will happen again (a rotation, an onboarding, an "add X"), especially one that failed partway. It gets a declared command, even if it ran only once here.
- **Human dependency:** every point where the work waited on the owner: an approval prompt, a timeout, a GUI click, "run this yourself". For each, can it run unattended within the trust boundary? If not, say what still needs them.
- **Instructions:** steering text that changed nothing (a no-op), a rule that belongs in a check or in review standards instead of an always-loaded file, or a statement in an instruction or doc this work touched that the current code, config or guard contradicts.

### Code architecture: where is the touched code fighting us?

Load the `codebase-design` skill and use its vocabulary (module, interface, depth, seam, adapter, leverage, locality). Scope to the modules this work touched and the repository's recent hot spots (`git log`). Read the ADRs in that area so you don't re-propose a recorded decision.

- **Shallow modules:** an interface nearly as complex as its implementation. Apply the deletion test: would deleting the module concentrate complexity, or just move it?
- **Leaky seams:** tightly coupled modules reaching across each other.
- **Lost locality:** understanding one concept means bouncing between many small modules, or bugs hide in how extracted pieces are called.
- **Hard to test:** code that could only be tested through workarounds this session (frozen clocks, test-only hooks, mocks of internals).

A candidate that contradicts an ADR is surfaced only when the friction is real enough to reopen it, and it is marked as such.

## 3. Present and file

Present one list across all three lenses, ranked by consequence: what breaks or slows down, for whom, and how soon. Each finding gets its lens, its evidence, a one-line fix and a size (small / medium / large).

For each finding the user accepts, open an issue in the owning repository with the evidence, what is wanted and any constraints. A small fix inside this work's scope can be done now instead, with the user's agreement. For an accepted architecture candidate, walk its design through with the user before filing it.

Done when every accepted finding has an issue or a merged fix.

If work continues in a fresh session, offer `/session-handoff`.
