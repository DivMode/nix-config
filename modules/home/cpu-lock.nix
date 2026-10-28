{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Persistent state, outside the cache paths pruned by caches.nix.
  lockDirectory = "${config.xdg.stateHome}/cpu-lock";
in
{
  home.packages = [
    (pkgs.writeShellApplication {
      name = "cpu-lock";
      text = ''
        exec ${pkgs.python3}/bin/python3 ${../../scripts}/cpu-lock.py \
          ${lib.escapeShellArg lockDirectory} "$@"
      '';
    })
  ];
}
