# Shottr: screenshot capture, annotation and OCR. The cask is declared in
# ../darwin/homebrew.nix. Shottr runs with its own defaults; the only
# declared change is telemetry off.
#
# Shottr is sandboxed, so its preferences live in
# ~/Library/Containers/cc.ffitch.shottr/Data/Library/Preferences. `defaults`
# reaches that file through cfprefsd by bundle id, which is what Home
# Manager's `defaults import` uses. `allowTelemetry` was read back from the
# domain as a boolean after Shottr 1.9.3 wrote it (2026-11-11); it is on by
# default, and Shottr queued launch events within a minute of first start.
{
  lib,
  pkgs,
  ...
}:
let
  domain = "cc.ffitch.shottr";
  settings.allowTelemetry = false;
in
{
  targets.darwin.defaults.${domain} = settings;

  # Shottr keeps its settings in memory, so a changed value needs a restart.
  # Ordered quit, write, relaunch so nothing the app saves on its way out can
  # land on top of the declared value, and only when the stored value
  # differs: a rebuild that changes nothing here leaves Shottr alone. Quit
  # with the standard quit Apple event, not a signal, and waited on through
  # LaunchServices; see restartLinearMouse in ./mouse.nix for why.
  home.activation.quitShottrForSettings =
    lib.hm.dag.entryBetween [ "setDarwinDefaults" ] [ "writeBoundary" ]
      ''
        shottrSettingsChanged=$(${pkgs.python3}/bin/python3 -I ${./defaults-changed.py} ${domain} ${pkgs.writeText "shottr-settings.json" (builtins.toJSON settings)})
        shottrWasRunning=0
        if [[ $shottrSettingsChanged == changed && -n "$(/usr/bin/lsappinfo find bundleid=${domain})" ]]; then
          shottrWasRunning=1
          run /usr/bin/osascript -e 'tell application id "${domain}" to quit' || true
          for _ in {1..50}; do
            [[ -n "$(/usr/bin/lsappinfo find bundleid=${domain})" ]] || break
            /bin/sleep 0.2
          done
          if [[ -n "$(/usr/bin/lsappinfo find bundleid=${domain})" ]]; then
            echo "warning: Shottr did not quit; its new settings apply at its next start" >&2
            shottrWasRunning=0
          fi
        fi
      '';

  home.activation.relaunchShottr =
    lib.hm.dag.entryAfter [ "setDarwinDefaults" "quitShottrForSettings" ]
      ''
        if [[ $shottrWasRunning == 1 && -d /Applications/Shottr.app ]]; then
          run /usr/bin/open -gj /Applications/Shottr.app \
            || echo "warning: Shottr was quit to apply its settings but could not be relaunched" >&2
        fi
      '';

}
