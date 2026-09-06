# The activation writer for Prime Agent's global settings.json, and its tests.
#
# Separated from the Home Manager module so `nix flake check` can run the tests
# without evaluating a host — the same arrangement ../../ai/codex uses for the
# Codex config merger. The module and the test drive the SAME script file, so a
# green check is a statement about what activation actually runs.
{ pkgs }:
let
  writer = ./command-governor-settings.sh;

  tests =
    pkgs.runCommand "command-governor-settings-tests"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.jq
          pkgs.python3
        ];
      }
      ''
        python3 ${./command-governor-settings-test.py} ${writer} ${pkgs.jq}/bin/jq
        touch "$out"
      '';
in
{
  inherit writer tests;
}
