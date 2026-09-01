{
  pkgs,
  ...
}:
let
  # ONE askpass helper, for every consumer that needs one.
  #
  # It existed twice before: as a let-binding inside ./sudo.nix, reachable only
  # by sudo(8) itself, and as scripts/sudo-askpass.sh for scripts/rebuild.sh.
  # ./homebrew.nix now needs the same dialog, and a third copy of an osascript
  # string is exactly the kind of duplicate that drifts. This module owns it and
  # hands it to the others as a module argument.
  #
  # It grants nothing. sudo still demands the correct password; this only
  # decides WHERE the prompt is drawn when there is no terminal to draw it in.
  sudoAskpass = pkgs.writeShellScript "sudo-askpass" ''
    exec /usr/bin/osascript \
      -e 'display dialog "A privileged installer needs your macOS account password." with title "Administrator password required" default answer "" with hidden answer buttons {"Cancel", "Continue"} default button "Continue"' \
      -e 'text returned of result'
  '';
in
{
  _module.args.sudoAskpass = sudoAskpass;
}
