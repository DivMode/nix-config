# Shell environment for Tandem-owned Herdr panes, and its tests.
#
# ── The defect ──────────────────────────────────────────────────────────────
# A Claude worker opened by Tandem printed "Transcript saving is off … --resume
# will not find this session". Measured on this Mac 2026-08-29, not inferred:
#
#   * The pane's environment carries CLAUDE_CODE_CHILD_SESSION=1.
#   * The Herdr server for Tandem's own session carries it too; the personal
#     `default` session's server does not.
#
# Claude Code stamps that marker onto every subprocess it starts, so whichever
# Claude session first ran `herdr` handed it to that server permanently, and
# every workspace the server creates inherits it. Tandem does not strip it:
# bridge/herdr-session.ts `sessionCommandEnv` removes only HERDR_* keys.
#
# The decision is Claude Code's own, read out of the 2.1.251 binary rather than
# guessed at:
#
#   if (FORCE_SESSION_PERSISTENCE) return false;                  // never warn
#   if (!(CHILD_SESSION && … && !isTeamAgent)) return false;
#   return !isChildSessionMarkerAmbientInTmux();
#
# So the warning needs the marker set, no force flag, no genuine team context,
# and a marker that is not ambient in tmux — which it never is here, because
# the multiplexer is Herdr. The binary states both remedies itself: "unset it
# and restart", or "restart with CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 to
# keep future transcripts".
#
# ── Why the force flag, and not unsetting the marker ────────────────────────
# CLAUDE_CODE_CHILD_SESSION is not noise. It is how a nested Claude declares
# itself a child so `--resume` in the PARENT does not offer the child's
# transcript. Unsetting it would strip that meaning from every invocation in
# the pane and is the more destructive of the two remedies Anthropic prints, so
# this takes the other one.
#
# It is not free, and the cost should be stated rather than discovered. The
# export lands in the pane's shell, so EVERY `claude` started there inherits it
# — including a genuinely nested one. For that child the suppression is
# switched off too: its transcript is written and becomes a `--resume`
# candidate in its parent, which is exactly what the marker exists to prevent.
#
# Accepted deliberately. The session this exists for is the top-level worker
# Tandem opened, whose transcript must survive; nesting inside a Tandem pane is
# rare, and a spare resume candidate is a far smaller harm than the top-level
# worker's transcript vanishing. Revisit if nested sessions become normal here
# — the fix then is for Tandem to set the flag on the agent it starts rather
# than on the shell that starts it, which needs a change in Tandem, not here.
#
# ── Why a shell snippet, and not the workspace environment ──────────────────
# Tandem's herdrWorkspaceEnvironment() returns `{ PATH }` and nothing else, so
# TANDEM_HERDR_WORKSPACE_PATH cannot carry a second variable at the pinned
# revision. Widening it is a change to Tandem, not to this repository.
#
# HERDR_SESSION is the scope. Herdr sets it in every pane, so matching Tandem's
# own session name reaches Tandem's panes and no others: the personal session's
# panes carry a different value and never take the export. If Tandem is
# configured onto the `default` session it is sharing the personal one, and the
# snippet is empty rather than global.
{
  pkgs,
  lib ? pkgs.lib,
}:
let
  variable = "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE";

  # `.zshenv`, not `.zshrc`: Herdr may start the agent from a non-interactive
  # shell, which never reads `.zshrc`. Same reasoning as the service-account
  # token in ../../secrets.nix.
  #
  # Only builtins are used, so this is safe before PATH is rebuilt — a Tandem
  # workspace starts with the PATH the module composes and nothing else.
  forceSessionPersistence =
    herdrSession:
    if herdrSession == "" || herdrSession == "default" then
      ""
    else
      ''
        # Tandem-owned Herdr panes only. See modules/home/ai/tandem/workspace-env.nix.
        #
        # `''${HERDR_SESSION-}`, not `$HERDR_SESSION`: .zshenv is read by EVERY
        # zsh, including ones started with NO_UNSET, and a bare reference to an
        # unset parameter there prints "HERDR_SESSION: parameter not set" on
        # stderr of every shell outside Herdr. Measured 2026-08-29 — noise in
        # every non-Herdr shell, and stderr some caller may be parsing.
        if [[ "''${HERDR_SESSION-}" == ${lib.escapeShellArg herdrSession} ]]; then
          export ${variable}=1
        fi
      '';

  # Behavioural, not textual: the snippet is run by a real zsh under each
  # HERDR_SESSION value that matters, and what the shell ends up with is what
  # is asserted. A grep would pass on a snippet whose condition never fires.
  tests =
    pkgs.runCommand "tandem-workspace-env-tests"
      {
        nativeBuildInputs = [ pkgs.zsh ];
        managed = forceSessionPersistence "tandem";
        namedOtherwise = forceSessionPersistence "workers";
        onDefaultSession = forceSessionPersistence "default";
        unconfigured = forceSessionPersistence "";
        passAsFile = [
          "managed"
          "namedOtherwise"
          "onDefaultSession"
          "unconfigured"
        ];
      }
      ''
        fail() { echo "tandem-workspace-env: $*" >&2; exit 1; }

        # Run a snippet under a given HERDR_SESSION and print what the variable
        # became. `env -u` so an inherited value cannot fake a pass.
        probe() {
          local snippet="$1" session="$2"
          env -u ${variable} HERDR_SESSION="$session" \
            zsh -c ". $snippet; printf '%s' \"\''${${variable}-<unset>}\""
        }

        # The same, with HERDR_SESSION genuinely ABSENT rather than empty, under
        # NO_UNSET, capturing stderr. .zshenv is read by every zsh on the
        # machine, so a snippet that is merely noisy outside Herdr is a defect.
        probeUnsetStrict() {
          env -u ${variable} -u HERDR_SESSION \
            zsh -c "set -u; . $1; printf '%s' \"\''${${variable}-<unset>}\"" 2>&1
        }

        # 1. Tandem's own pane gets the flag.
        [ "$(probe "$managedPath" tandem)" = "1" ] \
          || fail "a pane in the Tandem session did not get ${variable}=1"

        # 2. The personal session's panes do NOT. This is the rule that keeps
        #    the fix off the user's own workspaces.
        [ "$(probe "$managedPath" default)" = "<unset>" ] \
          || fail "a pane in the personal default session was given ${variable}"

        # 3. Nor does any other session, or a pane outside Herdr entirely.
        [ "$(probe "$managedPath" somethingelse)" = "<unset>" ] \
          || fail "an unrelated Herdr session was given ${variable}"
        [ "$(probe "$managedPath" "")" = "<unset>" ] \
          || fail "a pane with no HERDR_SESSION was given ${variable}"

        # And says nothing while doing it. Any diagnostic here reaches the
        # stderr of every shell on the machine that is not a Tandem pane.
        [ "$(probeUnsetStrict "$managedPath")" = "<unset>" ] \
          || fail "with HERDR_SESSION unset under NO_UNSET the snippet was not silent: $(probeUnsetStrict "$managedPath")"

        # 4. The session name is not hardcoded: a differently named Tandem
        #    session scopes to itself and still ignores the personal one.
        [ "$(probe "$namedOtherwisePath" workers)" = "1" ] \
          || fail "a differently named Tandem session did not get ${variable}=1"
        [ "$(probe "$namedOtherwisePath" tandem)" = "<unset>" ] \
          || fail "the snippet leaked across session names"

        # 5. Tandem sharing the personal session, or unconfigured, emits
        #    NOTHING. There is no session to scope to, so a global export would
        #    be the one outcome this must never produce.
        [ ! -s "$onDefaultSessionPath" ] \
          || fail "a Tandem configured onto the default session emitted a snippet"
        [ ! -s "$unconfiguredPath" ] \
          || fail "an unconfigured Tandem emitted a snippet"

        touch "$out"
      '';
in
{
  inherit forceSessionPersistence tests;
}
