{ pkgs }:
let
  python = pkgs.python3.withPackages (pythonPackages: [ pythonPackages.tomlkit ]);

  managedPreferences = {
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
