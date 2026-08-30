# Orchestration architecture

How a browser conversation ends up running engineering work on this Mac, who is
allowed to decide what, and which parts of that are declared here rather than
left to a running process.

This is the **design record**. Two neighbouring documents are deliberately not
this one, and each keeps its own job:

- [`ai/tandem/README.md`](../ai/tandem/README.md) is the **operator runbook** —
  what to check, in what order, when something is broken.
- [`ai/instructions/orchestration.md`](../ai/instructions/orchestration.md) is
  the **always-loaded policy** every local worker is given. It carries a line
  budget because it is a per-prompt tax on every session of every project, so
  it states rules and not reasons. The reasons are here.

Nothing in this file is loaded into a model's context automatically. That is
the point of writing the long version down somewhere else.

## 1. The system, in one picture

```text
        the user                     ← ultimate intent authority
           │
           ▼
      ChatGPT Web                    ← foreman: plans, routes, reviews, merges
           │  MCP over the OpenAI Secure MCP Tunnel (outbound only)
           ▼
      tunnel-client  (launchd)       ← Nix-owned runtime
           │  stdio
           ▼
      Tandem MCP server              ← execution and session bus
           │  herdr backend
           ▼
      Herdr session `tandem`         ← authoritative PTY and session runtime
           │
           ├── Claude Code worker     ← implementation / review
           └── Codex worker (opt-in)
                   │
                   ▼
              GitHub                 ← durable truth: issues, PRs, commits, CI
```

Every arrow is a different kind of thing, and confusing them is where most of
the failure modes in section 12 come from:

- **The user → ChatGPT** arrow carries *intent*. It is the only one that can
  change what the work is.
- **ChatGPT → Tandem** carries *control*. It is stateless, request-scoped, and
  can be interrupted at any moment without affecting anything downstream.
- **Tandem → Herdr → worker** carries *execution*. It outlives the conversation
  above it. This asymmetry is the single most important property of the whole
  design.
- **Worker → GitHub** carries *record*. Anything that must survive is written
  there, not into a transcript.

## 2. Roles and authority

The primary use case is **ChatGPT Web as the human-facing engineering foreman
for all projects** on this machine. Not one project, not a special case: the
default way work is planned and dispatched.

| Actor | Authority | Not their job |
| --- | --- | --- |
| **The user** | Ultimate intent authority. Decides what is worth doing, what a project means, and overrides everything below. | Being the message bus between agents. |
| **ChatGPT Web** | Foreman: plans, sequences, owns issue and session routing, reports. **Reviewer of record and merge authority.** | Implementation. It drives workers; it is not one. |
| **GitHub** | Durable work and source of truth: issues, pull requests, commits, review results, CI. | Live messaging. It is not the bus. |
| **Tandem** | Persistent local execution and session bus. Opens, addresses, polls, and interrupts sessions. Enforces session, polling, and model routing server-side. | Remembering the project. It holds running work, not history. |
| **Claude Code / Codex** | Local implementation and review workers. Produce code, tests, and evidence. | Approving their own work, or merging it. |

Two consequences are worth stating flatly, because they are the ones that get
eroded first:

**The user is not a router.** If the foreman narrates what a worker *should* be
asked instead of asking it, the person has been turned into a copy-paste
transport between two models. Tandem exists precisely so that does not happen.

**Implementation workers do not self-approve.** A worker's own account of its
work is not an independent review. Evidence goes to the foreman; the foreman
decides what merges.

## 3. Two bootstrap channels, and why both exist

The single most misunderstood part of this system: **there is no one document
that tells every participant how to behave.** There are two, with different
owners, different delivery mechanisms, and no automatic link between them.

| Audience | Channel | Owned by |
| --- | --- | --- |
| Claude Code, Codex (local) | `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, generated from `ai/instructions/` | this repository |
| ChatGPT Web (remote foreman) | MCP `initialize` result's `instructions`, the `get_orchestration_policy` tool, and per-tool descriptions | Tandem, at the pinned revision |

### Why the local channel cannot serve ChatGPT

`~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` are **files on this Mac**. A
browser session cannot read them. There is no mechanism — no upload, no sync,
no connector — by which a normal ChatGPT Web conversation acquires the contents
of a local dotfile. Any design that assumes otherwise is assuming a capability
that does not exist.

### Why the MCP channel cannot serve local workers

The MCP brief reaches whoever connects to Tandem. Claude Code and Codex running
locally on a project are not connected to Tandem — they are the things Tandem
*starts*. Their instructions must be present before any tool call happens, which
is what a Nix-rendered user-memory file is for.

### What each channel actually guarantees

The asymmetry matters when the two disagree:

- The local channel is **loaded automatically and unconditionally**. Claude Code
  reads its user memory for every project; Codex reads `$CODEX_HOME/AGENTS.md`
  as global user instructions. If the file is on disk, it was read.
- The MCP `initialize` instructions are, by the specification, a **hint**. A
  client MAY use it, MAY paste it into a system prompt, or MAY ignore it
  entirely. So a foreman that never called `get_orchestration_policy` has not
  necessarily seen the policy at all.

That is why Tandem does not rely on the brief being read. The rules that must
hold — session reuse, polling, model routing, the Fable consent gate — are
**enforced in the router and fail closed** whether or not any client read a
word of them. Text persuades; the router decides.

### Keeping the two semantically aligned

There is no automatic check that spans both, and there cannot be one from
inside this repository: the other document lives in a pinned external revision.
So the discipline is procedural and deliberately small:

1. **A rule that must bind both has to be written in both.** The local policy
   says so about itself, in the commentary a worker reads first.
2. **Moving the pin is when they are compared.** Changing `inputs.tandem` in
   `flake.nix` means re-reading that revision's `src/orchestration-policy.ts`
   against `ai/instructions/orchestration.md` and reconciling deliberately.
   `nix flake update` cannot move the pin, so this comparison cannot be skipped
   by an unattended lock bump.
3. **When the far end acts against a local rule, quote the rule.** Do not assume
   it already knows. It may genuinely never have been told.
4. **Prefer enforcement to prose for anything that matters.** If a rule is worth
   having, ask whether it can live in the router instead of in two documents.

**Where the two currently stand.** At policy **v1.2.0** — the version served by
the pinned revision — both documents carry the same four things that were most
at risk of existing on only one side:

| Rule | Local policy | Tandem policy v1.2.0 |
| --- | --- | --- |
| Reviewer of record and merge authority, stated in the **role** | Roles section | `roles` + `reviewAuthority` |
| No self-approval; an independent reviewer is optional and is evidence | Binding rules | `reviewAuthority` |
| No monitor-only sessions; a health probe is exceptional and closed at once | Binding rules | `monitoring` |
| Reconcile with `list_sessions` **and** `get_foreman_events`; events are history | Binding rules | `reconciliation` |

They arrived from opposite directions, which is the point: the reviewer and
monitor rules were written here first (nix-config #27) and carried across by
Tandem #5; the reconciliation rule was written there first (Tandem #4) and
carried back here. Neither repository is the upstream of the other.

## 4. The canonical policy, and the checks that hold it up

Local worker bootstrap is generated, not hand-maintained.

```text
ai/instructions/global.md        ─┐                        ┌─ ~/.claude/CLAUDE.md
                                  ├─→ one text document ───┤
ai/instructions/orchestration.md ─┘                        └─ ~/.codex/AGENTS.md
                                             │
                                             └─ ~/.config/nix-config/ai/agent-instructions.md
                                                (review artifact)
```

`global.md` is owner-edited prose about how the owner works and what "done"
means. `orchestration.md` is machine-level coordination policy: general by
design, naming no project, no repository, and no issue.

`ai/instructions/default.nix` composes them and exposes the checks that
`flake.nix` publishes as `checks.<system>.agent-instructions`. Four things are
asserted, and each exists because of a specific way this can silently rot:

- **The rendered document is exactly its two sources, concatenated in order.**
  Without this, "one canonical source" is a convention rather than a fact, and
  anything could be appended downstream.
- **Both consumers equal the canonical text — not merely each other.** This is
  the distinction the check was rewritten for
  ([#26](https://github.com/DivMode/nix-config/pull/26), merge `095faaa`).
  Mutual equality is satisfied by an *identical wrong edit to both*: give each
  consumer `"preamble" + text` and the two files still match, the rendered
  document is still exactly its two sources, and every earlier check passes
  while both clients are handed a policy that is not canonical.
- **`orchestration.md` stays within its line budget.** It is loaded into every
  session of every project. Budget is what stops a policy becoming a manual.
- **Every binding rule's text still exists, and sits in the right section.** A
  rule can be reworded freely; deleting one fails the build. Placement is
  checked separately because a rule moved out of the numbered list into the
  surrounding commentary keeps every word and loses its force.

The document is composed as a **string** at evaluation time rather than built as
a derivation, and that is measured rather than stylistic:
`programs.claude-code.context` is typed `either lines path` and branches on
`lib.isPath`, which is false for a derivation, so passing one takes the `.text`
branch and is rejected by `home.file.<name>.text`'s own `nullOr lines` type.

### Role and model rules carried by that policy

Both channels carry the same routing intent, and Tandem additionally enforces it:

- **Opus 5 is the default** for implementation, hard debugging, architecture,
  and substantive review. A new Claude session gets it by omitting `model`; the
  server applies the default rather than deferring to whatever the host CLI is
  configured for.
- **Sonnet is a deliberate narrowing** — read-only inspection, a lookup, a rote
  edit under an already-decided plan. Chosen because the work is genuinely
  small, and said out loud.
- **Haiku is for trivial, low-risk helper work only.** Not a cost reflex.
- **Fable is explicit-user-opt-in only.** Never selected on a model's own
  initiative, however well it seems to fit; requesting it requires a consent
  field on the same call, set only when the user's *current* instruction asked
  for Fable by name. Without it the request is rejected outright, and the server
  never silently substitutes a different model — a rejection means ask the user
  or choose something else yourself.
- **Cost is the user's decision.** Do not downgrade important work to save
  usage; say that cost is the reason and let them choose.

## 5. Session discipline

The rules, and the failure each one prevents.

**List, then reuse, then create.** Before opening a worker, list existing
sessions and look for one that already owns this task or issue. Two workers on
one task produce two divergent answers and one merge conflict. `open_session` is
idempotent for a name that is already live — it returns the existing session
rather than starting a second engine — so a stable, descriptive name *per unit
of work* is what makes reuse actually happen.

**One owner per issue.** Name sessions after the task or issue they own, and
open them with the correct project working directory. "Who owns this?" must have
exactly one answer at any moment.

**Preserve a composite name exactly.** A returned `<device>:<local>` name is what
pins later calls to the same worker on the same machine. A bare name always means
local, and will route somewhere else on a fleet.

**A long turn is not a stuck turn.** `status: running` with a cursor means the
turn is still executing — it does not mean the instruction was lost. Poll the
*same* session with empty text and the cursor the previous call returned; empty
text reads only newer output and does not start a new turn. Never resend the
instruction: a resend queues a second instruction into a live turn and corrupts
the worker's state. A "prompt stalled" signal is a heuristic and is wrong often
enough to matter; it is not grounds for a resend.

**Do not hammer reads.** Rely on the reported working/idle state and space the
polls out. The cost of polling is context, and context is the scarce resource.

**Close when the work is genuinely finished**, not between turns. Sessions stay
open across turns on purpose — that is where the worker's accumulated context
lives.

## 6. Interruption and resume is a first-class invariant

This deserves its own section because it is the property most likely to be
violated by a well-meaning recovery attempt.

> **Interrupting the foreman does not stop the workers.**

A new user message interrupts the *conversation*. It does not cancel a Tandem
session that is mid-turn, and it must never be read as an instruction to kill,
restart, or replace one. The worker is a separate process on a real machine; the
turn keeps running.

The invariant in full:

1. After **any** interruption, redirection, reconnect, new conversation, or
   context loss, the first move is to **re-list the sessions and resume polling
   the same named worker** from where it was.
2. Never open a fresh session to "restart" work that was already in flight. That
   is how two workers end up doing the same job.
3. Stop or replace a worker only when the user explicitly asks, or when they have
   changed the task that worker owns.
4. If it is genuinely unclear whether in-flight work is still wanted: **say what
   is running and ask.** Do not silently abandon it, and do not silently start a
   second one.
5. `interrupt_session` is the only thing that stops a running turn. It is a
   deliberate act for a genuinely runaway turn, and the session stays open
   afterwards.

The reason this is an invariant rather than a preference: the failure is
*silent and expensive*. An abandoned worker keeps writing to the same branch
while a second worker starts from scratch, and nothing reports the collision
until a merge conflict or a confusing diff shows up much later.

## 7. Reviewer hierarchy

Established by [#27](https://github.com/DivMode/nix-config/pull/27) (merge
`e478c17`).

```text
implementation worker ──diff + original requirement──▶ ChatGPT foreman ──▶ merge
                            │                                 ▲
                            └── optional independent ─────────┘
                                Claude reviewer (evidence only)
```

- **ChatGPT is the reviewer of record and the merge authority.** That is a
  standing fact about the role, not a step in a checklist, which is why the
  policy check requires it to sit under *Roles* rather than in the numbered
  rules.
- **Implementation and review stay separate** for anything significant or risky,
  whenever practical. Give the reviewer **the diff and the original requirement**
   — not the implementer's summary. A summary is the implementer's own account,
  and reviewing it reviews the wrong artifact.
- **Implementation workers do not self-approve.** They hand evidence up.
- **A separate Claude reviewer is optional and risk-based.** Open one when the
  work earns a genuinely independent read:
  - security and anything touching credentials,
  - protocol and MCP behaviour,
  - Nix and system state, activation, launchd,
  - concurrency, shared state, and persistence,
  - migrations,
  - large refactors.
- **Its verdict is evidence, not merge authority.** It informs the foreman's
  decision and does not replace it.
- **Skip it for small, low-risk, plainly correct work — and say that you
  skipped it.** An unexplained skip is indistinguishable from an oversight.

Both halves of each rule are pinned by the policy checks, because either half
alone survives an edit that inverts the rule: "implementation and review stay
separate" without "do not self-approve" still lets a worker approve itself so
long as somebody else also looked; "a separate Claude reviewer is optional"
without "not a substitute" turns an optional second opinion into the merge
decision.

## 8. Monitoring discipline

> **Never open a Claude session solely to watch another one.**

Progress comes from three things that already exist: Tandem `list_sessions`,
semantic cursor polling of the session that owns the work, and the foreman
reconciling foreman events (section 9). A monitoring worker adds nothing to
that and costs a great deal.

**Why it is banned rather than discouraged.** The cost is not the model's price;
it is context, and it compounds in three places at once:

1. **The monitor's own context.** A watcher reads raw terminal output — the most
   token-dense, least information-dense text in the system. Scrollback contains
   spinners, progress bars, redrawn TUI frames, ANSI escapes, and repeated
   partial lines. A worker's semantic state (`working`, `blocked`, `idle`) is a
   handful of tokens; the transcript that state was derived from is thousands.
2. **The foreman's context.** The watcher then *summarises into the foreman*,
   so the foreman pays for the same information a second time, in a form it did
   not need. Large transcript dumps forwarded into the coordinating conversation
   are how a foreman runs out of room to hold the actual plan — which is the one
   thing only it holds.
3. **Ownership.** A second session pointed at the same task is a second session
   pointed at the same task. It is exactly the duplicate-owner condition the
   list-then-reuse rule exists to prevent, arriving through a side door.

And it learns nothing: the cursor already carries every semantic transition, and
`list_sessions` already carries liveness. A watcher is a worse copy of two
things that are free.

**The one exception.** A short-lived read-only health probe is justified when the
*semantic state itself* looks inconsistent — Herdr reports idle while Tandem
reports running, or a session's reported state contradicts what `list_sessions`
says. That probe is read-only, answers one question, and is **closed
immediately afterwards**. It is not a standing monitor with a short name.

## 9. Completion and wake-up

### The honest gap

Tandem workers outlive the conversation driving them. A turn that finishes while
the foreman is away has to be recorded somewhere, because:

> **Nothing Tandem does can wake a dormant ChatGPT Web conversation.**

Not the MCP connection, not a webhook, not a notification. This is a **client
capability that does not exist**, not a Tandem configuration gap. Tandem detects
completion perfectly well; what is absent is any way to deliver that to a chat
client that is not currently taking a turn.

| Mechanism | Reaches | Wakes a dormant chat? |
| --- | --- | --- |
| `get_foreman_events` | The foreman, on its **next** turn | No — the foreman must ask |
| The host's local events log | Anything on the host that tails it | No |
| A done-webhook | An HTTP endpoint you run | No |
| A phone push topic | Your **phone** | No — it wakes a *person* |

The phone push is the only thing that genuinely wakes anything, and what it
wakes is a human, who can then go and prompt the foreman. That is the honest top
of the escalation chain, and no part of this design pretends otherwise. No
browser automation, and no invented protocol.

### The foreman-event inbox

The design that replaces push with **durable, reconciled-on-next-turn** history:

```text
worker turn completes
   │
   ▼
turn ledger  ── claims the completion exactly once, per agent incarnation
   │
   ▼
events emitter ── the single emitter; log and inbox cannot disagree
   │
   ▼
foreman inbox ── bounded, redacted, retained, owner-only file
   │
   ▼  get_foreman_events(since: <client-carried checkpoint>)
ChatGPT's NEXT turn ── reconciles what it missed, then calls list_sessions
```

Four properties carry the design:

**Completion is a transition, not an observation.** The defect this replaced
emitted completion from the *read* path on a content test — roughly "the page is
idle and has text". That is an observation, not a boundary, and because a read
returns everything newer than the supplied cursor, **polling twice with the same
stale cursor — the documented recovery move after an interruption — manufactured
two completions for one turn**. It also invented completions for sessions Tandem
never drove, and resurfaced an interrupted turn as a success. A turn is now
opened by the send and its completion claimed exactly once.

**Dedupe is not cursor-derived.** A cursor is a byte offset under one backend and
a synthetic counter under another; the two are not comparable and neither is a
turn identity. Each backend reports a **per-incarnation agent identity** instead,
so a session reopened under the same name gets a new epoch and cannot inherit the
previous agent's turn or its event ids.

**The checkpoint is carried by the client, and there is deliberately no ack
tool.** The HTTP transport is stateless — no session id generator, a fresh
server per request — and carries **no client identity**. A server-side "acked"
flag could therefore only ever be *one global watermark for the whole machine*,
shared by every conversation and every script. The failure mode is silent and
bad: whichever reader acked last hides those events from every other reader, and
a foreman that never saw an event is told there is nothing to see. A
client-carried opaque checkpoint is per-client by construction, keeps the read
path writing nothing at all (which is what lets it be honestly read-only), is
idempotent, and cannot be corrupted by a concurrent reader. The cost is real but
small: the foreman carries an opaque string between turns, and one that loses it
restarts from the oldest retained event. Re-reading is far cheaper than silently
missing a completion.

**Events are history; `list_sessions` is liveness.** They answer different
questions and the feed must never be used for the second:

- a `completed` event does **not** mean the worker exited — sessions stay open
  between turns on purpose;
- the **absence** of an event does not mean nothing happened — retention is
  bounded, and a turn Tandem did not drive is deliberately not reported.

The rule for a foreman is: **call both, before opening anything.** Reconciliation
happens at the start of substantial work and again after any interruption,
reconnect, new conversation, or context loss.

Two flags mean exactly one thing each, because reads always move forward from the
caller's position: **`more`** is pagination (unread events remain; call again
with the returned checkpoint), and **`truncated`** is loss (events you never saw
were rotated away, or your checkpoint predates the current store — reconcile
against `list_sessions` instead of trusting the feed). A page cut short by a
limit is `more`, never `truncated`.

### MCP Tasks and subscriptions: the protocol, and this stack

Two separate claims live here, and conflating them is the mistake this section
exists to prevent.

**What the protocol offers.** MCP's `2026-07-28` revision moves **Tasks** out of
the experimental core into the `io.modelcontextprotocol/tasks` extension, with a
poll-based `tasks/get` and a new `tasks/update`; and it replaces unsolicited
notifications with a single **`subscriptions/listen`** stream that clients opt
into per notification type. So the protocol is not the thing standing in the
way, and it is wrong to say MCP lacks these. See
[Sources](#18-sources-and-external-constraints).

**What this stack currently runs.** Measured inside the pinned server as part of
Tandem PR #4, against the SDK it actually installs rather than against
documentation:

- `@modelcontextprotocol/sdk` **1.30.0**; `LATEST_PROTOCOL_VERSION`
  **`2025-11-25`** — the revision *before* Tasks and `listen` were added.
- At that version `tasks/*` ships only under the SDK's **experimental**
  directory, whose own header warns the APIs may change without notice.
- At that version there is **no `listen` and no general subscription**. The only
  subscribe verb is `resources/subscribe` — resource-scoped, client-initiated,
  and it still only delivers updates over a connection that is *already open*.
- **Decisively, and independent of protocol version:** the server builds a fresh
  MCP server and transport **per request** and tears both down when the response
  closes. A task cannot outlive the request that created it. Making Tasks
  meaningful here would first require converting the transport to stateful
  sessions with a shared task store — not an additive change.

**And even a fully current stack would not close the gap.** Both mechanisms are
**client-initiated by construction**. `tasks/get` is a poll. The listen stream
is opened by the client, and the TypeScript SDK's own 2026-07-28 guidance is
explicit that *"the server never sends an un-requested notification type"*. A
conversation nobody is currently having opens no stream and issues no poll, so
there is nothing for a server to deliver into. Waking a dormant ChatGPT Web
conversation is a **client** capability, and no MCP revision confers it on the
server.

So the pull-based inbox is the **correct current implementation**, not a
workaround for a protocol deficiency — and no substitute was invented: no custom
notification method, no proprietary SSE channel, no long-poll "wake" tool. A
fake protocol would be worse than the honest gap, because a client would have no
way to tell it from a real one.

**The adapter seam is real and specific.** The event store is shaped so a future
adapter consumes it without redesign — stable content-derived ids, a monotonic
sequence, an explicit kind. If the SDK moves to `2026-07-28` and the transport
becomes stateful, a task's status projects from the events for its session
(`completed`/`error` terminal, `blocked`/`needs_input` mapping to an
input-required state) and the store's sequence number is the change token a
listen stream fires on. That is a migration with a known shape, not a rewrite.
Note that the move is not free even then: in the TypeScript SDK's v2 line the
2026-07-28 revision is opt-in — *"nothing in v2 puts a 2026-07-28 byte on the
wire by default"* — and `tasks/*` is treated as deprecated wire vocabulary that
is answered with a method-not-found error on 2026 connections. The seam to build
against is the listen stream, not the task methods.

**What must not be claimed.** That ChatGPT Web can be asynchronously woken
today; that MCP as a protocol lacks Tasks or subscriptions; or that moving the
SDK forward would by itself deliver wake-up. The first is false, the second is
false as of `2026-07-28`, and the third confuses a transport upgrade with a
client feature.

## 10. Fleet events, device identity, redaction, retention

**Per-host recording.** Events are recorded where the work ran. A session driven
on a fleet device is recorded on that device; its own inbox is the truth for its
own work.

**One device per call, and no aggregate mode.** A foreman covering a fleet calls
`list_devices` and then reads events once per device. That avoids a cross-device
merge with partial-failure semantics, and avoids inventing a chronological order
across clocks that were never synchronised. An **offline device fails
explicitly**, naming that device and nothing else about it, so one unreachable
machine can never be mistaken for "nothing happened".

**The hub's routing id wins.** A device reports events under whatever id it was
configured with; the hub does not trust that. Every returned event's device and
session are rewritten to the id the hub actually routed to, so the composite name
a foreman reads back is always the name that will route to that worker.

**Reading a device cannot fan out.** A device executing an incoming events
request performs a pure local inbox read that knows nothing about a fleet
runtime, so there is no path by which the call recurses back into the fleet.

**Checkpoints are a versioned map, not a scalar.** Each device has its own store,
epoch, and sequence numbers, so one number cannot mean anything fleet-wide. The
token maps the hub's routing device id to that device's own cursor; reading one
device advances only that entry and preserves the others verbatim. The older
single-store token is still accepted and read as the local entry, and never
re-issued. The map ships before anything aggregates because **the token is the
part clients persist across turns** — getting its shape right later would be a
breaking migration that silently stranded every stored checkpoint.

**Retention is enforced on write.** At most 400 events, at most 14 days, with a
byte cap as a backstop, applied *before any reader sees the store*, so it cannot
grow without limit on a long-lived host. The store is one owner-only file in a
private directory, replaced atomically, and **rejected rather than trusted** when
its owner, permissions, size, or contents are wrong.

**The data boundary is narrow by construction.** The feed carries no working
directory, no filesystem path, no attach hint, no handoff block, no git facts, no
environment, no tool arguments, and no transcript — under any setting. Free text
is limited to a short summary and reason, clamped and redacted: absolute,
home-relative, Windows and UNC paths, URLs, email addresses, tailnet hosts and
addresses, API keys and tokens, JWTs, private-key blocks, `password=`-style
assignments, long hex digests and base64 blobs, and control bytes all go.
*Relative* repository paths are kept deliberately — they name a file inside the
repository the worker was already told to work in, carry no host or account
identity, and are most of what makes a summary worth reading.

Redaction is a **bounded best effort on free text, not a proof**: a determined
engine could still print something sensitive in a novel shape. There is a
setting that drops both free-text fields entirely and keeps only the structured
transition, and that is the setting to use if the residual risk is unacceptable.

## 11. Machine-level isolation

### The dedicated `tandem` Herdr session

Tandem workers live in a **dedicated, silent Herdr session named `tandem`**,
never the personal or default one. Established by Tandem
[#2](https://github.com/DivMode/tandem/pull/2) (`963c583`).

The reason is notification isolation. A remote foreman opening and driving
sessions all day generates a constant stream of agent-state notifications. In a
shared session those land in the user's own workspace, where they are
indistinguishable from notifications about work the user is personally doing.
Separating the sessions separates the two notification streams, and it also gives
the ownership rules something concrete to hold onto: Tandem attaches to a session
that is already running, tags the workspaces it creates as its own, and closes
only those. Personal workspaces, panes, and tabs are never modified, reset, or
closed.

**This is enforced, not merely recommended.** The module's option default is the
dedicated session, `local.example.nix` shows the same value to every new host,
and a configuration naming the personal `default` session **fails evaluation**.
`modules/home/ai/tandem/session.nix` holds the value once and checks all three
agree, plus the binding rule in the canonical policy that justifies them. The
original module shipped `default` as its default and the template repeated it,
which meant every host that did not think about it contradicted a binding rule
*and* silently disarmed the transcript fix below — the two failures compound,
and neither announces itself.

### Nix and launchd own the connector; the account owns the app

| Nix / Home Manager owns | Applications and runtime own |
| --- | --- |
| the pinned Tandem source and its Node runtime | the ChatGPT-side custom app and its approval — *account* state |
| the tunnel client binary | Herdr workspaces, panes, native session identity |
| Tandem's protected runtime configuration (non-secret only) | Tandem's mutable session inventory |
| the `herdr` backend selection | tunnel runtime state |
| the launchd agent that keeps the tunnel running | OAuth and login sessions |
| the status / doctor / restart operator wrappers | |

The runtime API key is in neither column, because this repository never handles
it. Nix stores the **path** it is read from; the file itself is the operator's to
create, `0600`, and no value ever reaches a Nix expression — evaluation copies
values into the world-readable store, and no later `chmod` undoes that.

The whole module is **off** until the host names at least one allowlisted working
directory. That is not a convenience: the allowlist is the admission boundary for
every session a remote model can open, so a default would be a default answer to
"which directories may a remote model write to". `/`, `/Users`, and the home
directory itself are rejected at evaluation time.

### The workspace PATH fix

A Herdr workspace inherits the environment of the **Herdr server**, not of the
shell that configured anything. An agent the server cannot see does not exist as
far as Tandem is concerned, and the failure does not announce itself: the pane
prints `command not found`, the command exits, the managed agent name disappears
with it, and Tandem reports a missing agent target — which reads like a lifecycle
bug and is not one.

The fix is a PATH scoped to Tandem's own disposable workspaces, and two details
of it are load-bearing:

- Herdr applies the value as the workspace's **entire** PATH, not as an addition
  to one. Emitting a host's extra entries verbatim handed a fresh workspace a
  single directory and broke zsh's own startup before any prompt appeared. So
  the module provides the standard macOS and Nix directories as a **floor** and
  only ever appends to it.
- The standard directories come **first**, deliberately. A host's extra entry
  exists to expose something the standard set lacks; leading entries would
  silently shadow a user's tool with an application bundle's private copy.

No global PATH changes. No shim. Nothing that makes an agent visible to Tandem
thereby appear in the user's own shell.

### Transcript persistence, and why it is scoped

A Claude worker opened by Tandem printed *"Transcript saving is off … `--resume`
will not find this session"*. The cause was measured on this Mac rather than
inferred: the pane's environment carries `CLAUDE_CODE_CHILD_SESSION=1`, and so
does the Herdr server for Tandem's own session — while the personal session's
server does not. Claude Code stamps that marker onto every subprocess it starts,
so whichever Claude session first ran `herdr` handed it to that server
permanently, and every workspace the server creates inherits it. Tandem does not
strip it; its environment filter removes only Herdr's own keys.

The consequence is exactly the thing the durability rules exist to prevent: the
**top-level worker's transcript is not written**, so nothing can resume it and
nothing survives the session closing.

Claude Code prints both remedies itself: unset the marker, or set
`CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1`. This machine takes the second.

**Why not unset the marker.** `CLAUDE_CODE_CHILD_SESSION` is not noise. It is how
a nested Claude declares itself a child so `--resume` in the *parent* does not
offer the child's transcript. Unsetting it strips that meaning from every
invocation in the pane, and is the more destructive of the two remedies.

**The cost, stated rather than discovered.** The export lands in the pane's
shell, so every `claude` started there inherits it — including a genuinely
nested one, whose transcript then becomes a resume candidate in its parent. That
is accepted deliberately: the session this exists for is the top-level worker
Tandem opened, nesting inside a Tandem pane is rare, and a spare resume candidate
is a far smaller harm than a top-level worker's transcript vanishing.

**Why it is scoped, and how.** The snippet is guarded on Herdr's own
`HERDR_SESSION` variable matching Tandem's configured session name. Tandem's
panes take the export; the personal session's panes carry a different value and
never do; a shell outside Herdr entirely never does. If Tandem is configured onto
the `default` session it is sharing the personal one, and the snippet is **empty
rather than global** — a session-scoped fix cannot be scoped to the session it
exists to stay out of. That branch is now unreachable through configuration,
because the module refuses the personal session outright, but it stays as a
guard: it is the reason the default had to change, and the reason a "why not
just point it at `default`" question has an answer. The guard is also written so
it stays silent under `NO_UNSET`, because the file it lands in is read by every
zsh on the machine and a diagnostic there would reach the stderr of every shell.

This is verified behaviourally, not textually — a real zsh runs the snippet under
each session value and the resulting environment is asserted. A textual check
would pass on a snippet whose condition never fires.

## 12. Data and control flow

### Dispatch: intent becomes execution becomes record

```text
user intent
   │
   ▼
┌──────────────┐  MCP tools: list_sessions → open_session → send_to_session
│ ChatGPT Web  │  (list and reuse BEFORE open)
└──────┬───────┘
       │ HTTPS, outbound only — nothing on this Mac listens publicly
       ▼
┌──────────────────────┐
│ Secure MCP Tunnel    │  control plane
└──────┬───────────────┘
       │
       ▼
┌──────────────────────┐  launchd keeps it running; Nix declares it
│ tunnel-client        │
└──────┬───────────────┘
       │ stdio
       ▼
┌──────────────────────┐  cwd allowlist = admission boundary
│ Tandem MCP server    │  model routing + Fable gate enforced HERE
└──────┬───────────────┘
       │ herdr backend, absolute store path
       ▼
┌──────────────────────┐  session `tandem`, never `default`
│ Herdr                │  owns the PTY, semantic state, agent identity
└──────┬───────────────┘
       │
       ▼
┌──────────────────────┐  reads ~/.claude/CLAUDE.md — the Nix-rendered policy
│ Claude Code worker   │
└──────┬───────────────┘
       │ branches, commits, pull requests, evidence
       ▼
┌──────────────────────┐
│ GitHub               │  durable truth; outlives every session
└──────────────────────┘
```

Live traffic is `ChatGPT ↔ Tandem ↔ Herdr ↔ agent`. **GitHub is not the message
bus** — it holds durable engineering state, not every agent message. The
human-visible end of live traffic is Herdr itself: watch or focus the same pane
directly rather than copying output anywhere.

### Completion: execution becomes history becomes the next turn

```text
worker finishes a turn
   │                                   (the foreman may be entirely absent here)
   ▼
turn ledger claims the completion ONCE, keyed by agent incarnation
   │
   ▼
single event emitter ──┬──▶ host events log      (tail-able locally)
                       ├──▶ optional webhook     (reaches a host endpoint)
                       ├──▶ optional phone push  (reaches a PERSON)
                       └──▶ foreman inbox        (bounded, redacted, retained)
                                   │
                                   │   ⟵ no push exists to close this gap ⟶
                                   │
                       ┌───────────┴────────────┐
                       │  the foreman's NEXT    │
                       │  turn, whenever it is  │
                       └───────────┬────────────┘
                                   ▼
                    get_foreman_events(since: checkpoint)   ← history
                                   +
                          list_sessions()                   ← liveness
                                   ▼
                       reconcile, THEN decide what to open
```

The dashed gap in the middle is the whole of section 9. It is closed by the
foreman asking, not by anything telling it.

## 13. Failure modes and runbook

Layered checks live in [`ai/tandem/README.md`](../ai/tandem/README.md). This is
the orchestration-level list: what the symptom actually means, and what to do.

| Symptom | Most likely cause | Do this |
| --- | --- | --- |
| A session is listed but has produced nothing for a long time | A long turn, not a stuck one | Poll the **same** session with empty text and the newest cursor. Do not resend. Space the polls out. |
| "Prompt stalled" or a soft wait expired | A heuristic firing on a real turn | Ignore it as a reason to act. It is wrong often enough to matter; a resend duplicates work already in flight. |
| No output at all while the state says working | Herdr's semantic state is the truth; screen text is not | Read Herdr's own `agent list` / `agent get`. `working`, `blocked`, and `idle` are reported, not guessed from screen scraping — a blocked session usually says what it is waiting for. |
| A worker finished but the chat never noticed | **Expected.** No client wake-up exists | Reconcile on the next turn: read foreman events with your checkpoint, then `list_sessions`. Never conclude from silence. |
| Two workers are editing the same files | A duplicate owner was created, usually after an interruption | Stop, name which session owns the task, close the other **after** preserving its work. Then fix the cause: list before open. |
| A `completed` event, but the session is still there | **Expected.** Sessions stay open between turns | Events are history. `list_sessions` is the only liveness truth. |
| `truncated: true` on an event read | Retention rotated, or the checkpoint predates the current store | Do not assume a full record. Reconcile against `list_sessions`. |
| The event feed is empty after a long absence | Bounded retention, or turns Tandem did not drive | Same answer: `list_sessions`, and read the durable record on GitHub. |
| `agent target … not found` right after opening a session | The Herdr **server's** environment cannot see the agent binary | Not a lifecycle bug. Check the workspace PATH; the doctor wrapper resolves it against exactly the directories Tandem will pass. |
| "Transcript saving is off" in a Tandem pane | The child-session marker was inherited from the Herdr server | Confirm the session-scoped persistence guard is active for the Tandem session. Do not fix it by unsetting the marker globally. |
| A test suite fails only inside a Tandem pane | The live machine's environment leaking into the harness | Re-run with the environment variables the harness takes as default parameters **unset**. Measured on the pinned Tandem revision: four failures with them set, zero with them unset, same commit. A harness that reads the live machine is the defect. |
| Work was done in the wrong checkout | A convenient second clone was treated as canonical | Confirm the repository root from the checkout itself before reading or changing anything. If two checkouts of one project exist, say so and ask which is canonical rather than picking. |
| The foreman reports tools unavailable | Anything from the tunnel outward | Work outwards from the machine using the runbook's ordered checks; a connector change needs a **new** conversation, because tool metadata is captured per conversation. |

**When to open a health probe.** Only when the *semantic state itself* looks
inconsistent — Herdr and Tandem disagreeing, or a session's state contradicting
`list_sessions`. Read-only, one question, **closed immediately**.

**Cleanup expectations.** Close a session when its work is genuinely finished,
not between turns. Closing removes only the Tandem-owned workspace, after
re-checking its ownership tags; personal workspaces are never touched. Before
closing anything, make sure the durable record is on GitHub — a finding that
exists only in a terminal transcript dies with the session.

## 14. State and privacy boundary

This repository is public. [`state-boundary.md`](state-boundary.md) draws the
general line; this is that line applied to orchestration.

**Never in tracked files:** secrets, tokens, keys, personal usernames, email
addresses, hostnames, private repository or project names, 1Password vault
names, tunnel ids, workspace ids, account identifiers, chat history, or session
data. Comments describe private things generically. The rule is enforced rather
than trusted: `scripts/check-private-names.sh` derives its denylist from the
ignored host file at run time — so the list itself never enters a tracked file —
and hooks block both committing and pushing a match.

**`local.nix` stays ignored**, and carries every host-specific orchestration
value: the cwd allowlist, the Herdr session name, extra engines, the workspace
PATH entries, the tunnel id, and the *path* to the runtime key.

**Secret values never enter a Nix expression.** Evaluation copies values into the
world-readable Nix store, and no later permission change undoes that. Nix stores
references and paths; the runtime reads the value.

**MCP payloads carry no paths and no secrets.** The event feed's boundary
(section 10) is the concrete form of this: no working directory, no filesystem
path, no environment, no tool arguments, no transcript. Free-text summaries are
clamped and redacted, and can be switched off entirely.

**Summaries are constrained on purpose.** A short, redacted summary is a
compromise between a foreman that can act on what it reads and a feed that is
safe to expose to a connected client. Relative repository paths survive because
they carry no host or account identity; anything absolute does not. The
constraint is a bounded best effort on free text, not a proof — which is why the
switch to drop it exists.

## 15. How this got here

Each merge solved a specific problem, and knowing which one prevents re-opening
a settled question.

| Change | Merge | What it solved |
| --- | --- | --- |
| Tandem #2 — Herdr bridge reliability | `963c583` | Moved Tandem onto its **own silent named Herdr session**, so a remote foreman's constant agent-state notifications stop landing in the personal workspace, and Tandem's ownership tags have something concrete to scope to. |
| Tandem #3 — ChatGPT bootstrap | `9c06f56` | Gave the remote foreman a policy at all. Added the `initialize` orchestration brief, the `get_orchestration_policy` tool, and **server-side** model routing that keeps Fable behind explicit consent. This is the only path by which a browser coordinator learns this machine's rules. |
| nix-config #24 — Tandem/Herdr module | `1388354` | Declared the whole local side: pinned fork, tunnel client, launchd agent, protected runtime configuration, operator wrappers, and the cwd allowlist as an admission boundary. Also the workspace PATH floor, after a single-directory PATH broke zsh's own startup. |
| nix-config #25 — global orchestration policy | `1fa58e9` | One canonical instruction document for **both** local clients, with checks that the rendered document is exactly its sources and that every binding rule survives editing. |
| nix-config #26 — assert consumers equal canonical | `095faaa` | Closed the gap where mutual equality between the two consumer files passed while both were handed non-canonical text. Each consumer is now tied to the canonical value, not to the other one. |
| nix-config #27 — reviewer/monitor hierarchy | `e478c17` | Named ChatGPT the reviewer of record and merge authority, forbade self-approval, made an independent Claude reviewer optional and risk-based, and **banned monitor-only sessions** in favour of semantic polling and event reconciliation. |
| Tandem #4 — foreman-event inbox | `c097bdc` | Made turn completion **durable and claimed exactly once**, and added the bounded, redacted inbox a returning foreman reconciles against. Completion used to be emitted from the *read* path, so polling twice with the same stale cursor — the documented recovery move after an interruption — manufactured two completions for one turn, invented completions for sessions Tandem never drove, and resurfaced interrupted turns as successes. Also brought fleet routing, device identity, retention and redaction. See sections 9 and 10. |
| Tandem #5 — reviewer/monitor governance | `afc3192` | Carried this repository's #27 governance across the second channel: reviewer of record and merge authority in the **role**, no self-approval, an optional risk-based independent reviewer whose verdict is evidence, and no monitor-only sessions. Policy **v1.2.0**. Currently pinned in `flake.nix`. |

The through-line: each step moved a rule from *being written down* to *being
enforced somewhere it cannot silently stop applying* — first in the router, then
in the flake checks, then in a durable event store.

## 16. Deferred: evaluating a different orchestration substrate

A general multi-agent orchestration framework is a real alternative to this
stack, and evaluating one is **explicitly deferred**, not rejected.

**Why Tandem was hardened first.** The system already existed and was already
carrying real work. Its failure modes were known, specific, and fixable — a
missing bootstrap channel, notification bleed into a personal session, a
duplicated completion, an unwritten transcript — and each fix was small, testable
and reversible. Replacing the substrate while those defects were live would have
meant debugging a new system and an old one at the same time, with no way to tell
which layer was wrong. Fix what you have until its remaining problems are
*structural* rather than incidental; that is when a substitute becomes a fair
comparison.

**What to compare it against, when the time comes.** Not features — these five:

1. **Durable ledger.** Does completion survive the coordinator being absent, and
   is it claimed exactly once? This is the property that took the most work to
   get right here, and it is easy to under-specify in a demo.
2. **Headless control.** Can it be driven entirely by tools, with no human
   pasting between windows, and does it enforce its rules server-side rather
   than trusting a prompt?
3. **Wake-up and browser delivery.** Does it actually close the gap in section
   9, or does it also reconcile on the next turn? An honest "no" is fine; an
   implied "yes" that turns out to be a polling loop is not.
4. **Multi-runtime.** Does it drive more than one agent CLI, and does it own the
   PTY, or does it need its own multiplexer alongside the one already installed?
5. **Complexity and ownership cost.** How much of it must this repository
   declare, pin, and keep working on a fresh Mac? A substrate that cannot be
   restored by `darwin-rebuild switch` is a step backwards from what exists now.

Any evaluation should compare against **the current state of this stack**, not
against the problems it had before the changes in section 15.

## 17. Unrelated: a known Homebrew activation defect

Recorded here only so it is not mistaken for an orchestration problem when it
appears during a rebuild. **It has nothing to do with Tandem, ChatGPT, or agent
sessions.**

A Tailscale cask is present in the local Homebrew installation, marked
*"installed (as dependency)"*, and is **not declared** in
`modules/darwin/homebrew.nix`. Homebrew activation reconciles to the declared
list with `cleanup = "uninstall"`, so it attempts to remove it; the cask
installs through a `.pkg` artifact, which is the class of cask whose removal is
least reliable, and the removal is the reported activation failure.

It is called out as separate because the symptom — a rebuild failing — is
exactly what a broken Tandem module change would also look like, and diagnosing
one as the other wastes a session. The resolution is an ordinary declaration
decision: either declare the cask so reconciliation stops trying to remove it,
or remove it deliberately and outside an activation run. Both are out of scope
for this document.

## 18. Sources and external constraints

Everything above that depends on somebody else's product or specification, with
the source it depends on. Two rules govern this section.

**Distinguish the specification from this installation.** "MCP supports X" and
"the server pinned in `flake.nix` supports X" are different claims, and only the
second one constrains what can be built here today. Section 9 keeps them apart
deliberately.

**Measurements beat documentation for the local half.** Every claim about the
pinned server was measured against the code and the installed SDK, not read off
a page. Every claim about the protocol or about ChatGPT's own behaviour comes
from the vendor, because nothing here can measure it.

### Model Context Protocol

| Source | What it establishes here |
| --- | --- |
| [Lifecycle, revision 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle) | That `InitializeResult.instructions` exists and is a **hint** — a client MAY use it, add it to a system prompt, or ignore it. This is why Tandem enforces its rules in the router rather than trusting the brief was read (section 3). |
| [Schema, revision 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25/schema) | The wire shape of that field, and the method inventory the PR #4 measurement was taken against. |
| [Using server instructions](https://blog.modelcontextprotocol.io/posts/2025-11-03-using-server-instructions/) | The intended role of server instructions: orientation for a connecting client, not an enforcement mechanism. The design consequence is section 3's "text persuades; the router decides". |
| [Tasks and subscriptions in MCP 2026-07-28](https://blog.modelcontextprotocol.io/posts/2026-07-28/) | That the protocol **does** have Tasks — moved into the `io.modelcontextprotocol/tasks` extension with a poll-based `tasks/get` and a new `tasks/update` — and a single opt-in `subscriptions/listen` stream. Cited so nobody reads section 9 as "MCP cannot do this". |
| [TypeScript SDK: supporting 2026-07-28](https://ts.sdk.modelcontextprotocol.io/v2/migration/support-2026-07-28) | That adopting it is opt-in rather than automatic, that `tasks/*` is deprecated wire vocabulary answered with method-not-found on 2026 connections, and that the server never sends an un-requested notification type — the client opens the listen stream. This is what makes both mechanisms client-initiated. |

### OpenAI and ChatGPT

| Source | What it establishes here |
| --- | --- |
| [Chat preferences / custom instructions](https://help.openai.com/en/articles/8096356-chat-preferences-for-chatgpt) | That ChatGPT's own personalization is an **account-level chat preference applied to conversations**, not a per-project channel and not an API mechanism. It is therefore not a way to deliver this machine's orchestration policy: it is neither versioned, nor reviewable, nor derived from the repository. The MCP bootstrap in section 3 is the channel; this is why there is no third one. |
| [Developer mode and full MCP connectors](https://help.openai.com/en/articles/12584461-developer-mode-and-full-mcp-connectors-in-chatgpt-beta) | The ChatGPT-side setup the runbook's one-time steps follow: developer mode, a custom connector, write-capable actions for unattended steering, and the Secure MCP Tunnel connection type this Mac uses. Also why tool metadata is captured **per conversation**, which is the reason a connector change needs a new chat rather than a refresh. |

These two are account-side product behaviour. They are cited rather than
measured, and they are the part of this document most likely to age: an OpenAI
product change can invalidate a section here without anything in this repository
changing. Re-read them when the ChatGPT side behaves unexpectedly, before
assuming the local stack is at fault.

### This installation, measured

| Claim | Where it was measured |
| --- | --- |
| SDK `1.30.0`, protocol `2025-11-25`, `tasks/*` experimental-only, no general subscription | Tandem PR #4, against the installed SDK in the pinned tree |
| Fresh MCP server and transport **per request**, torn down on response close | The pinned server's own HTTP transport construction |
| Retention: 400 events / 14 days / byte backstop, enforced on write | Tandem PR #4 |
| No client identity across requests, hence no server-side ack | Tandem PR #4; the reason the checkpoint is client-carried (section 9) |
| Typecheck clean, 55 test files / 670 tests passing at the pinned commit | Run against `afc3192` with the harness environment variables unset |
| `CLAUDE_CODE_CHILD_SESSION=1` present in the Tandem session's Herdr server and absent from the personal one | Measured on this Mac; see `modules/home/ai/tandem/workspace-env.nix` |
| A single-directory workspace PATH breaks zsh startup before the first prompt | Measured on this Mac with a disposable workspace |
