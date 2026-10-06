{ config, local, ... }:
let
  # The Herdr Server.app launcher's stderr log (../home/herdr/server-app.nix),
  # read from the agent itself so the path is declared in one place. Herdr's
  # own server log (~/.config/herdr/herdr-server.log) needs nothing here:
  # Herdr rotates it itself at 5 MB (src/logging.rs, DEFAULT_MAX_LOG_BYTES).
  herdrLauncherLog =
    config.home-manager.users.${local.user}.launchd.agents.herdr-server.config.StandardErrorPath;
in
{
  # Rotated by macOS's own newsyslog, which launchd already runs hourly for
  # the system logs and which reads every file in /etc/newsyslog.d; checking
  # one more file's size costs nothing measurable.
  #
  # Fields: file, owner:group, mode, archives kept, size in KB, when, flags.
  # Rotate past 1 MB (years away: the launcher logs a line only when it starts
  # or restarts the server — 790 bytes on its first day), keep 3, so the log
  # can never take more than about 4 MB. `*`: by size only. `N`: there is no
  # process to signal. No compression: launchd keeps the file open, so after
  # a rotation the launcher writes into the renamed copy until it restarts,
  # and compressing would delete that copy and lose those lines.
  environment.etc."newsyslog.d/nix-config.conf".text = ''
    ${herdrLauncherLog}  ${local.user}:staff  644  3  1024  *  N
  '';
}
