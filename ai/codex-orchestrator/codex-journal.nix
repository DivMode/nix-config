{ pkgs }:
pkgs.writeShellApplication {
  name = "codex-journal";
  runtimeInputs = [
    pkgs.jq
    pkgs.git
    pkgs.coreutils
  ];
  text = builtins.readFile ./codex-journal.sh;
}
