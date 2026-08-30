# The one canonical global instruction document, and the checks that keep it
# honest.
#
# Two tracked sources, one rendered document, two destinations:
#
#   global.md        ─┐                     ┌─ ~/.claude/CLAUDE.md
#                     ├─→ document (text) ──┤
#   orchestration.md ─┘                     └─ ~/.codex/AGENTS.md
#
# Both clients load their file automatically for every project — Claude Code as
# user memory, Codex as global user instructions under $CODEX_HOME. Neither is
# read by ChatGPT on the web, which is why the policy says so itself.
#
# The document is composed at EVALUATION time with `readFile` rather than built
# as a derivation and handed to both consumers. That is not a stylistic choice:
# `programs.claude-code.context` is typed `either lines path` and branches on
# `lib.isPath`, which is FALSE for a derivation. Passing one therefore takes the
# `.text` branch, where `home.file.<name>.text` is `nullOr lines` and rejects
# it outright:
#
#   error: A definition for option `…CLAUDE.md".text' is not of type
#   `null or strings concatenated with "\n"'
#
# Measured against the pinned home-manager, not assumed — it fails loudly at
# evaluation rather than writing a store path as the file's content. A plain
# string takes the `lines` branch in both clients.
{
  pkgs,
  lib ? pkgs.lib,
}:
let
  # Behaviour, taste, and machine rules. Owner-edited prose.
  global = builtins.readFile ./global.md;

  # How agents coordinate with each other. Kept separate because it has a
  # different author, a different review cadence, and a line budget: it is
  # loaded into every session of every project, so it stays short.
  orchestration = builtins.readFile ./orchestration.md;

  text = global + "\n" + orchestration;

  # For review and for the tests below. NOT what the clients are given; see the
  # comment above.
  document = pkgs.writeText "agent-instructions.md" text;

  # Every rule the orchestration policy exists to carry, expressed as a string
  # that must survive editing. A rule can be reworded freely; deleting one
  # fails the build, which is the point — these were asked for explicitly and
  # must not be lost to a tidy-up.
  requiredPhrases = [
    # Where this document is loaded — and, just as binding, where it is not.
    "Codex reads it as global user instructions from `$CODEX_HOME/AGENTS.md`"
    "Claude Code reads it as user memory from `~/.claude/CLAUDE.md`"
    "**ChatGPT on the web does not read either file**"
    "`get_orchestration_policy`"

    # Roles.
    "**GitHub** is the durable source of truth."

    # Session handling.
    "**List, then reuse, then create.**"
    "**Tandem workers live in the dedicated `tandem` Herdr session.** Never the"
    "personal or default Herdr session."
    "Poll the *same* session with empty text and the cursor the"
    "**Interrupting the foreman does not stop the workers.**"
    "re-list the sessions and resume polling the"
    "same named worker**"

    # Model routing. The Fable rule is the one most likely to be softened by a
    # well-meaning reword, so both halves of it are pinned.
    "Default to **Opus 5** (`opus`)"
    "**Never use Fable unless"
    "the user explicitly asks for Fable by name.**"

    # Everything else that was asked for explicitly.
    "**Implementation and review stay separate**"
    "**Checkpoint durably.**"
    "**This machine is declarative.**"
    "**Work in the intended checkout.**"
    "**No hidden fleets.**"
    "**A more specific instruction file wins on its own ground.**"
  ];

  # One phrase per line. Every phrase is therefore a SINGLE line of the policy,
  # matched as a fixed string against a single line of the document.
  #
  # Enforced, not merely stated: a phrase containing a newline would split into
  # two independent greps that each pass on weaker text than the phrase was
  # written to pin. That degrades silently, so it throws instead.
  multiLinePhrases = builtins.filter (phrase: lib.hasInfix "\n" phrase) requiredPhrases;

  requiredPhrasesFile =
    if multiLinePhrases != [ ] then
      throw ''
        ai/instructions: a required phrase spans more than one line, which would
        silently weaken the check into two independent matches. Split it into
        one entry per line, or shorten it to a single line of the policy:
        ${builtins.concatStringsSep "\n" multiLinePhrases}
      ''
    else
      pkgs.writeText "agent-instructions-required-phrases" (
        builtins.concatStringsSep "\n" requiredPhrases + "\n"
      );

  maxOrchestrationLines = 150;

  tests =
    pkgs.runCommand "agent-instructions-tests"
      {
        inherit document;
        globalSource = ./global.md;
        orchestrationSource = ./orchestration.md;
      }
      ''
        fail() { echo "agent-instructions: $*" >&2; exit 1; }

        # The rendered document is exactly its two tracked sources, in order.
        # This is what makes "one canonical source" a checked claim rather than
        # a convention: nothing can be appended to the rendered file that is not
        # in a source file.
        cat "$globalSource" > expected
        printf '\n' >> expected
        cat "$orchestrationSource" >> expected
        cmp -s expected "$document" \
          || fail "the rendered document is not global.md followed by orchestration.md"

        # The policy is loaded into every session of every project, so its size
        # is a per-prompt tax on everything. Keep it a policy, not a manual.
        lines=$(wc -l < "$orchestrationSource")
        [ "$lines" -le ${toString maxOrchestrationLines} ] \
          || fail "orchestration.md is $lines lines, over the ${toString maxOrchestrationLines}-line budget"

        # Fixed strings, not patterns, and matched against the whole rendered
        # document so a rule moved between the two sources still counts.
        while IFS= read -r phrase; do
          [ -n "$phrase" ] || continue
          grep -qF -- "$phrase" "$document" \
            || fail "missing binding rule text: $phrase"
        done < ${requiredPhrasesFile}

        touch "$out"
      '';
in
{
  inherit text document tests;
}
