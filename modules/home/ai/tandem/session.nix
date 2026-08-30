# Which Herdr session Tandem owns, as one value with the reasoning attached.
#
# ── Why this is not just a string in an option default ──────────────────────
# Binding rule 3 of ai/instructions/orchestration.md is absolute: "Tandem
# workers live in the dedicated `tandem` Herdr session. Never the personal or
# default Herdr session." Two separate mechanisms depend on that being true,
# and BOTH fail silently when it is not:
#
#   * Notification isolation. A remote foreman opening and driving sessions all
#     day produces a constant stream of agent-state notifications. On the
#     personal session they are indistinguishable from notifications about work
#     the user is doing personally. DivMode/tandem PR #2 moved Tandem onto its
#     own silent session precisely to end that.
#   * Transcript persistence. ./workspace-env.nix scopes
#     CLAUDE_CODE_FORCE_SESSION_PERSISTENCE to Tandem's OWN session by matching
#     HERDR_SESSION. Configured onto `default`, that snippet is deliberately
#     EMPTY rather than global — a session-scoped fix cannot be scoped to the
#     session it is supposed to stay out of. So a host on `default` loses its
#     workers' transcripts and is told nothing.
#
# The original module shipped `default` as the option default and
# local.example.nix repeated it, which meant every host that did not think
# about it contradicted a binding rule and disarmed the transcript fix. That is
# the regression this file exists to make impossible to reintroduce quietly:
# the value lives here once, ./default.nix must use it, local.example.nix must
# agree with it, and the policy must still carry the rule that justifies it.
{
  pkgs,
  lib ? pkgs.lib,
}:
let
  # The dedicated, silent Herdr session Tandem attaches to. A host may still
  # name a different one in local.nix — some machines have their own naming —
  # but it may not be the personal `default` session, and ./default.nix asserts
  # that.
  dedicatedSession = "tandem";

  # The personal session. Named so the rule below reads as a rule rather than
  # as a comparison against a magic string.
  personalSession = "default";

  workspaceEnv = import ./workspace-env.nix { inherit pkgs lib; };

  # The exact source line ./default.nix must carry. A shared constant only
  # helps while it is actually the thing being used; without this, restoring
  # `tandemLocal.herdrSession or "default"` by hand would pass every other
  # check in this file.
  requiredModuleDefault = "default = tandemLocal.herdrSession or dedicatedSession;";

  # What local.example.nix must show a new host. The template is the only thing
  # most hosts ever read, so a template that disagrees with the rule is the
  # rule not existing.
  requiredExampleValue = ''herdrSession = "${dedicatedSession}";'';

  # The binding rule this whole file serves. If it is deleted from the policy,
  # the assertions below are enforcing something nothing states any more.
  requiredPolicyPhrase = "**Tandem workers live in the dedicated `tandem` Herdr session.** Never the";
in
{
  inherit dedicatedSession personalSession;

  tests =
    pkgs.runCommand "tandem-session-tests"
      {
        inherit dedicatedSession personalSession;
        moduleSource = ./default.nix;
        exampleSource = ../../../../local.example.nix;
        policySource = ../../../../ai/instructions/orchestration.md;

        # The snippet ./workspace-env.nix produces for the dedicated session.
        # Non-empty is the whole point: this is the transcript fix engaging.
        dedicatedSnippet = workspaceEnv.forceSessionPersistence dedicatedSession;
        personalSnippet = workspaceEnv.forceSessionPersistence personalSession;
        passAsFile = [
          "dedicatedSnippet"
          "personalSnippet"
        ];
      }
      ''
        fail() { echo "tandem-session: $*" >&2; exit 1; }

        # 1. The session Tandem owns is not the personal one. This is the
        #    regression itself, stated as directly as it can be.
        [ -n "$dedicatedSession" ] \
          || fail "the dedicated Herdr session name is empty"
        [ "$dedicatedSession" != "$personalSession" ] \
          || fail "Tandem is configured onto the personal '$personalSession' Herdr session"

        # 2. And the consequence, checked rather than trusted: on the dedicated
        #    session the transcript-persistence snippet actually fires, and on
        #    the personal one it stays silent. A default that emits nothing is
        #    how the transcript defect came back.
        [ -s "$dedicatedSnippetPath" ] \
          || fail "the dedicated session produces no transcript-persistence snippet; workers would lose their transcripts"
        grep -q 'CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1' "$dedicatedSnippetPath" \
          || fail "the dedicated session's snippet does not export the persistence flag"
        [ ! -s "$personalSnippetPath" ] \
          || fail "the personal session was given a transcript-persistence snippet"

        # 3. The module actually uses the constant. Without this the constant
        #    is decoration and a hand-edited literal passes everything above.
        grep -qF -- ${lib.escapeShellArg requiredModuleDefault} "$moduleSource" \
          || fail "modules/home/ai/tandem/default.nix no longer defaults herdrSession to the shared constant"

        # 4. The template a new host copies agrees with the rule.
        grep -qF -- ${lib.escapeShellArg requiredExampleValue} "$exampleSource" \
          || fail "local.example.nix no longer shows ${requiredExampleValue}"

        # 5. The policy still carries the rule these assertions enforce.
        grep -qF -- ${lib.escapeShellArg requiredPolicyPhrase} "$policySource" \
          || fail "ai/instructions/orchestration.md no longer carries the dedicated-session rule"

        touch "$out"
      '';
}
