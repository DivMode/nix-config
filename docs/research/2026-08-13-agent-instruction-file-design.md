# Designing agent instruction files, skills, and skill descriptions

Research date: 2026-08-13

Sources:

1. Theo (t3.gg), "I Fixed Claude Without Touching Any Code" —
   <https://www.youtube.com/watch?v=e1snsuY4lTI> (51 min). A rewrite of global
   and project instruction files, plus skill design.
2. Warren, Better Stack, "Want to Run Your Agents For Hours? Use These 12 Rules
   for Claude.md" — <https://www.youtube.com/watch?v=D4uBfIe7SzA> (9 min), and
   the example `CLAUDE.md` published alongside it, which implements those rules
   almost section for section.

The first source's files are deliberately unpublished. He states twice that the
value is the reasoning and the path he took, not his wording, and compares
copying someone's skills to installing every npm package another developer
uses. This note therefore records the *arguments*, so they can be applied to
our own failures rather than transcribed.

The two sources are independent and agree on more than they differ. Where they
agree, the point is probably load-bearing. Where they differ, the first is
mostly about how the agent *communicates*, and the second mostly about how it
*behaves*.

## Conclusion

The purpose of an agent instruction file is not to make the model a better
programmer. It is to make the model **communicate better with you**. Almost
every specific recommendation below follows from that.

Three changes carry most of the value:

1. A **glossary** in each project's instruction file — so the agent reports
   back in your vocabulary, not so it understands you.
2. **Skill descriptions written as trigger keywords**, not explanations,
   because the description is loaded on every turn whether the skill fires or
   not.
3. **Deriving the rules from an audit of your own history**, rather than from
   imagination about what an agent might get wrong.

## The global file

Least important of the set, in his estimation, but three additions earned their
place:

- **Introduce yourself to the agent** — who you are, what you build, what you
  value. The mechanism is tone matching: models mirror the register they are
  written in, so the introduction shapes how replies come back. Two sentences
  about preferring less code measurably calmed over-eager models.
- **"Questions are read-only."** Stops an agent editing when it was only asked
  about something.
- **"Match ceremony to the task."** No sub-agents or review panels for work a
  single pass finishes; delegation is for breadth or adversarial review. Where
  agents do run in parallel, state file ownership up front, because they
  collide otherwise.

## The project file

**It is not a README, and the difference is the whole point.** A README helps a
human or agent decide whether to use the code. The instruction file explains how
to *change* things here and what to know before changing them. His framing: it
should not be written for developers; it should be written for agents, so that
the agent interacts with the developer better.

What he found worth including:

- **A glossary.** The highest-value section, and for a non-obvious reason: not
  so the agent can understand you — it can usually infer that — but so it
  **describes things back to you in your own terms**. He defines even
  trivially obvious words: *you*, *we/maintainers*, *user*, *agent*,
  *provider*, *client*, *environment*, *project*.
- **A short "never compromise on" list**, so the agent knows what it must not
  damage while making an unrelated change.
- **A personal note carrying taste**: do not preserve complexity because it
  already exists; do not add machinery because it looks architecturally
  impressive; YAGNI; fight scope creep.
- **An explicit statement that these are good defaults, not hard rules**, and
  that the person prompting can override any of them. Without it, the agent
  argues with the user, which is worse than the rule being missed.
- **Paired bad and good examples.** He rates one concrete bad example plus its
  good counterpart above any amount of prose, on the grounds that it seeds the
  model with your specific taste. He applies this to PR titles and PR
  descriptions in particular: lead with the problem in plain language, never
  with an inventory of what was implemented.
- **Surface and entry-point checklists**, to stop a change landing on one
  client and not the others.
- **Reverse states** — if a feature adds an action, say that its inverse is
  required too.
- **Environment safety** — do not kill the dev server, or the very instance the
  contributor is working inside.

## Skill descriptions

The single most transferable tip. A skill's description is **always in
context**, whether or not the skill is used; only its body is deferred.
Therefore the description should be **the trigger keywords**, not a summary of
what the skill does. His phrasing: think of it as trigger keywords rather than
as an actual description.

Consequences he acted on:

- Overloaded skills split in two, each with a short, trigger-focused
  description, once the keywords were good enough to route reliably.
- Trigger phrasing extended to bare mentions — "if they mention X with no
  additional context, use this skill" — so a one-word prompt fires it.
- Descriptions that explain the whole skill are a per-turn context tax for no
  routing benefit.

## The method — how he decided what to add

He did not write the rules from imagination. He had agents **audit his own
session history** for failure modes, categorised by model and harness, with
frequencies: corrections per hundred user messages, tool misuse, over-building,
stopping early, the rate at which draft PRs were opened instead of real ones.
Then he had them propose file changes from that evidence.

Two habits he recommends alongside it:

- When an agent does something wrong, ask it **why** it made that decision.
  Often it read something earlier that pointed the wrong way.
- When a simple request takes far too long, ask it to **categorise its tool
  calls** into useful and wasted.

## Where the second source agrees

Independent confirmation of the same ideas, argued differently:

- **Size is a correctness issue, not tidiness.** Keep the file short — the
  second source uses 500 lines as its cap — because the file enters the context
  of every prompt and model reliability degrades as context grows. Overflow
  goes to nested per-directory instruction files or to skills.
- **Vocabulary consistency.** Same conclusion as the glossary, reached from the
  other side: pick one word per concept and never coin a second. Its example
  file expresses this as a table of concept, the word to use, and the words
  never to use — which doubles as the paired good/bad examples the first source
  recommends.
- **Do not assume; ask.** One question up front is cheaper than half a day in
  the wrong direction. Its example file also asks the agent to list any
  assumption it could not resolve at the top of its summary — a good refinement,
  since it makes the assumption visible rather than merely discouraged.
- **An architecture section with a lookup table**, so a session does not
  re-explore the tree every time. Its heuristic is worth keeping verbatim in
  spirit: if the agent is repeatedly searching for something, that thing is a
  candidate for the instruction file.
- **Long workflows belong in skills**, not in the instruction file.

## The failure-log discipline

The strongest idea in the second source, and it is attributed rather than
invented: Mitchell Hashimoto treats Ghostty's agent file as a **failure log**,
where every line exists because an agent made that specific mistake at least
once.

Two things make it work:

- **A protocol for keeping it current**, written into the file itself: when
  corrected, add one line in the imperative describing the correct behaviour,
  keep it specific to this repository, put workflows in skills instead, and
  ship it in the same commit as the fix.
- **A stated size ceiling**, so the log cannot grow without something else
  being moved out.

This is the same conclusion the first source reaches by a different route — he
derives his rules from an audit of real failures rather than from imagination.
One arrives at it by discipline, the other by measurement.

It is also a better place for this than the assistant's own memory: memory is
per-machine, tied to one vendor's client, and not version-controlled, so it
neither survives a rebuild nor reaches anyone else.

## Rules can be harness-specific

The first source writes rules aimed at a particular harness, not only at a
particular model:

- A rule to open real pull requests rather than drafts, added because one
  harness reliably opened drafts that then went unreviewed.
- A rule that a pull request should state which model and harness produced it —
  with the caveat that one harness frequently cannot report its own model, and
  sometimes names the wrong one.
- "Provider" defined in the glossary as the runtime or harness, with a rule
  that a feature shipped by one provider needs an explicit decision for each
  other adapter, even if that decision is "not supported here".

His history audit was also categorised **by model and harness**, and the
failure modes differed sharply between them: one aggressively killing the wrong
process, another filing drafts a large fraction of the time, another misreading
intent.

The implication for us is concrete. Rendering one instruction file to both
clients — which is what this repository does today, from
`ai/instructions/global.md` — is right for everything that is genuinely about
how work should be done, and wrong for anything that exists because a specific
harness misbehaves. A shared file has nowhere to put "this harness opens drafts,
tell it not to". Either such rules are kept out of the shared source and added
per client, or the shared source grows a small per-client section. Nothing here
needs changing until we actually observe a harness-specific failure, but when
we do, the single shared file is the constraint we will hit.

## Where they differ, and why

The difference is emphasis, and it tracks what each author is doing:

- The first is about **communication**: introducing yourself, tone matching, the
  glossary as a way for the agent to describe work back in your words,
  trigger-keyword skill descriptions, rules as overridable defaults.
- The second is about **behaviour**: the test loop, strict type checking,
  dependency vetting, performance budgets, error handling, end-to-end and UI
  passes with realistic data.

The likely reason is a difference in bottleneck. The first runs many agents in
parallel across several machines and harnesses, landing large numbers of pull
requests; at that volume the limiting factor is reading and trusting the
output, so his rules optimise the human-agent interface. The second is
explicitly about running an agent unattended for long stretches, where the
limiting factor is the agent going wrong while nobody is watching, so its rules
are guardrails that hold without supervision.

A second reason is subject matter. The first writes for a real product with
users and invariants, so his project file encodes what must never be damaged.
The second's example is a generic application, so it encodes generic
engineering standards.

They also genuinely conflict on one point, and it is worth resolving
deliberately rather than averaging. The first insists rules are good defaults
that the person prompting can always override, because an agent arguing with
its user is worse than a rule being missed. The second's example file is
absolute — never report success on a red loop, no escape hatches in the type
system.

Both are right about different rules. Safety and correctness rules should be
absolute: they exist because the cost of breaking them is unrecoverable. Taste
and style rules should be defaults: they exist because they are usually right.
A file that makes everything absolute trains the agent to argue; a file that
makes everything a default has no teeth where it matters. Say which kind each
section is.

A file that only does behaviour reads as a rulebook, and the agent will follow
it while still reporting work in language you have to translate. A file that
only does communication is pleasant and vague. Both are wanted.

## How this applies here

Measured against the above, on the date of this note:

- `ai/instructions/global.md` is pure behaviour. It lacks the self-introduction,
  "questions are read-only", and ceremony-matching.
- Project instruction files in this fleet carry rules and architecture but no
  **glossary**, no note of personal taste, no definition of *you* / *we* /
  *the user*, and no statement that the rules are defaults the user may
  override. Repositories with dense in-house vocabulary suffer most: an agent
  that cannot name things the way the maintainer does will keep reporting work
  in terms the maintainer has to translate.
- Skill descriptions are mixed. Some already list trigger phrases; others are
  explanatory prose that costs context on every turn and buys no routing.

The audit method is the item to apply first, because it replaces guessing about
what our agents get wrong with evidence about what they actually got wrong.

## What our project files already do well

Worth recording so it is not "improved" away. The work monorepo's instruction
file already implements several of these without naming them:

- Its DO/DON'T tables are exactly the paired good and bad examples the first
  source recommends, and they are specific rather than generic.
- Its reference table is the "where things live" lookup the second source asks
  for.
- Directory-scoped files already exist for two subtrees, which is the nested
  instruction file pattern.
- Long workflows already live in skills rather than inline.
- Many rules are already failure-derived, and several cite the incident and date
  that produced them. That is a failure log — it is simply distributed through
  the document instead of collected under a heading, which makes it harder to
  append to but no less true.

The gaps against both sources are: no glossary, no protocol for keeping the
file current, no statement of which rules are absolute and which are defaults,
and no definition of *you*, *we*, or *the user*.
