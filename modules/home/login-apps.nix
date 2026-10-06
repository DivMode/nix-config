{ lib, pkgs, ... }:
let
  # Applications that must be running after every login, by bundle id and
  # path. Their own "Start at login" switches are SMAppService registrations,
  # which no configuration can declare, so on a new home directory they are
  # simply off: after the first restart on 2026-10-06 LinearMouse was not
  # running until it was started by hand four minutes after boot, and the
  # mouse scrolled the trackpad's way until then.
  #
  # Thaw is deliberately absent: the owner does not want it started.
  apps = {
    "com.lujjjh.LinearMouse" = "/Applications/LinearMouse.app";
  };

  # Launched through LaunchServices with `open`, never by exec'ing the binary.
  # That is what makes this safe beside the application's own login item, if
  # one is ever switched on: `open` without -n hands an already running (or
  # starting) instance the request instead of starting a second process, so
  # two copies never filter the same mouse events — the failure that removed
  # the previous agent on 2026-08-13, which ran the binary directly. The
  # `lsappinfo` check skips apps that are already up, so a running app is not
  # even sent a reopen event that could bring its window forward.
  startApps = pkgs.writeShellScript "start-login-apps" (
    lib.concatStrings (
      lib.mapAttrsToList (id: path: ''
        if [ -z "$(/usr/bin/lsappinfo find bundleid=${id})" ] && [ -d ${lib.escapeShellArg path} ]; then
          /usr/bin/open -gj ${lib.escapeShellArg path}
        fi
      '') apps
    )
  );
in
{
  # Runs once at login. Not KeepAlive: if an application is quit on purpose it
  # stays quit until the next login. A rebuild reloads this agent only when its
  # plist changes, and then the check above leaves running apps alone.
  launchd.agents.start-login-apps = {
    enable = true;
    config = {
      ProgramArguments = [ "${startApps}" ];
      RunAtLoad = true;
      ProcessType = "Interactive";
    };
  };
}
