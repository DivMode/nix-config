{ pkgs }:
let
  python = pkgs.python3.withPackages (pythonPackages: [ pythonPackages.tomlkit ]);

  managedPreferences = {
    # Re-asserted on every activation because something outside this repository
    # keeps resetting it. Reported 2026-08-27 as "defaults to medium after
    # every rebuild", against a stored `model_reasoning_effort = "xhigh"`.
    #
    # merge-config.py is NOT the cause, and that is established rather than
    # assumed: merge_table only adds or updates the keys declared here and has
    # no delete path, so an undeclared key is carried through untouched. The
    # value was simply never owned by anything, so nothing put it back once the
    # application changed it.
    #
    # What changes it is unproven. The candidate is the ChatGPT desktop app:
    # ../../modules/darwin/homebrew.nix upgrades its cask during activation,
    # which quits and replaces the application, and a build that does not
    # recognise a stored value would write its own default over it. Recorded as
    # a hypothesis; no activation has yet been observed changing the byte.
    #
    # Declaring it fixes the symptom whatever the mechanism turns out to be,
    # because activation now re-asserts the value after the upgrade that
    # disturbs it. If the desktop application still shows "medium" after a
    # rebuild while this file reads "xhigh", the effort the UI uses is stored
    # somewhere other than config.toml and that is the next thing to find.
    #
    # `model` is deliberately not declared. Only the effort was reported lost,
    # and the model is a per-session choice this repository has no reason to own.
    model_reasoning_effort = "xhigh";

    approval_policy = "never";
    approvals_reviewer = "auto_review";
    sandbox_mode = "danger-full-access";

    apps._default = {
      approvals_reviewer = "auto_review";
      default_tools_approval_mode = "approve";
      destructive_enabled = true;
      enabled = true;
      open_world_enabled = true;
    };
  };

  preferencesToml =
    (pkgs.formats.toml { }).generate "codex-managed-preferences.toml"
      managedPreferences;

  merger = pkgs.writeShellApplication {
    name = "merge-codex-config";
    runtimeInputs = [ python ];
    text = ''
      exec python3 ${./merge-config.py} "$@"
    '';
  };

  tests = pkgs.runCommand "merge-codex-config-tests" { nativeBuildInputs = [ python ]; } ''
    python3 ${./merge-config-test.py} ${merger}/bin/merge-codex-config ${preferencesToml}
    touch "$out"
  '';
in
{
  inherit merger preferencesToml tests;
}
