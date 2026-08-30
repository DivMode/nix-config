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

  # The rule both consumers are held to, as a function so that the assertion in
  # modules/home/ai and the regression test below exercise the SAME predicate
  # rather than two restatements of it that can drift apart.
  #
  # Each consumer must equal `text` — the canonical value — and not merely equal
  # the other one. That distinction is the whole point. Mutual equality is
  # satisfied by an IDENTICAL wrong edit to both consumers: give each of them
  # `"preamble" + text` and the two files still match each other, the rendered
  # document is still exactly its two tracked sources, and every check that
  # existed before this one passes while both clients are handed a policy that
  # is not the canonical document.
  consumersMatchCanonical =
    {
      claudeText,
      codexText,
    }:
    claudeText != null && codexText != null && claudeText == text && codexText == text;

  # Drift shapes for the test below: a client-specific preamble, which is the
  # edit the post-merge review actually described, and an appended line, which
  # is the same mistake from the other end.
  preambleDrift = "# Claude-specific preamble.\n\n" + text;
  appendedDrift = text + "\n# Appended after the canonical document.\n";

  # A Nix function cannot be called from the test's shell, so the predicate is
  # applied here and only its verdicts cross into the derivation.
  verdict = pair: if consumersMatchCanonical pair then "match" else "drift";

  # Some rules are binding only because of WHERE they sit. A rule moved out of
  # the numbered list into the surrounding commentary keeps every word and
  # loses its force, and the whole-document check below cannot see that: it
  # matches the text wherever it appears. These phrases must additionally be
  # found inside a named section of orchestration.md.
  #
  # The reviewer of record belongs in Roles because it is a standing fact about
  # who ChatGPT is, not a step to follow; the other three are obligations, and
  # an obligation that is not a binding rule is a suggestion.
  sectionPhrases = {
    "## Roles" = [
      "It is also the **reviewer of record and the merge authority** for"
    ];
    "## Binding rules" = [
      "**Implementation and review stay separate**"
      "**Implementation workers do not self-approve**"
      "**A separate Claude reviewer is optional, not mandatory.**"
      "**Never open a Claude session solely to watch another one.**"
    ];
  };

  # Every rule the orchestration policy exists to carry, expressed as a string
  # that must survive editing. A rule can be reworded freely; deleting one
  # fails the build, which is the point — these were asked for explicitly and
  # must not be lost to a tidy-up. The section-placed phrases above are folded
  # in here so they inherit the whole-document check and the one-line guard
  # rather than restating either.
  requiredPhrases = builtins.concatLists (builtins.attrValues sectionPhrases) ++ [
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

    # The second half of each reviewer/monitor rule; the first half of each is
    # in `sectionPhrases` above. Both halves are pinned because either one
    # alone survives an edit that inverts the rule. "Implementation and review
    # stay separate" without "do not self-approve" still lets a worker approve
    # itself so long as somebody else also looked. "A separate Claude reviewer
    # is optional" without "not a substitute" turns an optional second opinion
    # into the merge decision. And a ban on monitoring sessions without the
    # mechanism that replaces them leaves a foreman no way to see progress at
    # all, which is how the banned session gets opened again.
    "the ChatGPT foreman, not a substitute for its review and merge decision**."
    "progress comes from Tandem `list_sessions`, semantic cursor polling of the"
    "**closed immediately afterwards**."

    # Everything else that was asked for explicitly.
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
  # written to pin. That degrades silently, so it throws instead. A tab is
  # rejected for the same reason — it is the field separator of the section
  # file below, and one inside a phrase would truncate the phrase to whatever
  # precedes it.
  unsafePhrases = builtins.filter (
    phrase: lib.hasInfix "\n" phrase || lib.hasInfix "\t" phrase
  ) requiredPhrases;

  checkedPhrases =
    if unsafePhrases != [ ] then
      throw ''
        ai/instructions: a required phrase spans more than one line or contains a
        tab, which would silently weaken the check into two independent matches.
        Split it into one entry per line, or shorten it to a single line of the
        policy:
        ${builtins.concatStringsSep "\n" unsafePhrases}
      ''
    else
      requiredPhrases;

  requiredPhrasesFile = pkgs.writeText "agent-instructions-required-phrases" (
    builtins.concatStringsSep "\n" checkedPhrases + "\n"
  );

  # `<section heading>\t<phrase>`, one pair per line. Guarded by the same throw:
  # `checkedPhrases` is forced here, so a phrase carrying a tab or a newline
  # cannot reach this file whichever list it was written into.
  sectionPhrasesFile = builtins.deepSeq checkedPhrases (
    pkgs.writeText "agent-instructions-section-phrases" (
      lib.concatStrings (
        lib.mapAttrsToList (
          section: phrases: lib.concatMapStrings (phrase: "${section}\t${phrase}\n") phrases
        ) sectionPhrases
      )
    )
  );

  maxOrchestrationLines = 150;

  tests =
    pkgs.runCommand "agent-instructions-tests"
      {
        inherit document;
        globalSource = ./global.md;
        orchestrationSource = ./orchestration.md;

        # One verdict per scenario. The pair is what the two Home Manager
        # consumers would be given; the answer is what the assertion makes
        # of it.
        verdictCanonical = verdict {
          claudeText = text;
          codexText = text;
        };
        verdictBothPreamble = verdict {
          claudeText = preambleDrift;
          codexText = preambleDrift;
        };
        verdictBothAppended = verdict {
          claudeText = appendedDrift;
          codexText = appendedDrift;
        };
        verdictClaudeOnly = verdict {
          claudeText = preambleDrift;
          codexText = text;
        };
        verdictCodexOnly = verdict {
          claudeText = text;
          codexText = preambleDrift;
        };
        verdictMissing = verdict {
          claudeText = null;
          codexText = null;
        };
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

        # Where a rule sits is part of what it means. The check above passes on
        # a rule reworded into the commentary above the numbered list, which
        # reads as background rather than an obligation; this one does not.
        # Sections run from their `## ` heading to the next one.
        while IFS="$(printf '\t')" read -r section phrase; do
          [ -n "$phrase" ] || continue
          awk -v want="$section" '
            /^## / { inside = ($0 == want); next }
            inside { print }
          ' "$orchestrationSource" > section-body
          [ -s section-body ] \
            || fail "orchestration.md has no \"$section\" section to place rules in"
          grep -qF -- "$phrase" section-body \
            || fail "rule text is outside the \"$section\" section: $phrase"
        done < ${sectionPhrasesFile}

        # The consumer rule, case by case. This is a regression test for the
        # predicate; the assertion in modules/home/ai is what applies it to the
        # real `home.file` entries, and it fires during `darwin-rebuild` and
        # `nix eval .#darwinConfigurations.<host>.system`.
        [ "$verdictCanonical" = match ] \
          || fail "the canonical document was rejected for both consumers; every rebuild would fail"

        # THE gap this test exists for. Both consumers drift by the SAME bytes,
        # so they still equal each other: the mutual-equality rule alone passes
        # this, and the canonical rule must not.
        [ "$verdictBothPreamble" = drift ] \
          || fail "an identical client-specific preamble on BOTH consumers was accepted as canonical"
        [ "$verdictBothAppended" = drift ] \
          || fail "an identical appended line on BOTH consumers was accepted as canonical"

        # One-sided drift, checked here too so this rule stands on its own
        # rather than leaning on the mutual-equality assertion beside it.
        [ "$verdictClaudeOnly" = drift ] \
          || fail "a preamble on ~/.claude/CLAUDE.md alone was accepted as canonical"
        [ "$verdictCodexOnly" = drift ] \
          || fail "a preamble on ~/.codex/AGENTS.md alone was accepted as canonical"

        # `programs.claude-code.context = ""` writes no CLAUDE.md at all, which
        # leaves `.text` null. Absent is not canonical.
        [ "$verdictMissing" = drift ] \
          || fail "a consumer with no content at all was accepted as canonical"

        touch "$out"
      '';
in
{
  inherit
    text
    document
    consumersMatchCanonical
    tests
    ;
}
