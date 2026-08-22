{
  local,
  pkgs,
  ...
}:
let
  # Same dialog as scripts/sudo-askpass.sh, but reachable by sudo itself rather
  # than only by a script that remembers to export SUDO_ASKPASS.
  askpass = pkgs.writeShellScript "sudo-askpass" ''
    exec /usr/bin/osascript \
      -e 'display dialog "A privileged installer needs your macOS account password." with title "Administrator password required" default answer "" with hidden answer buttons {"Cancel", "Continue"} default button "Continue"' \
      -e 'text returned of result'
  '';
in
{
  # An askpass helper sudo can find without the environment.
  #
  # READ THIS BEFORE REACHING FOR IT AGAIN. It does NOT make unattended cask
  # installs work, which is what it was added for on 2026-08-21. Measured that
  # day, in a shell with no controlling terminal:
  #
  #   sudo /usr/bin/true        FAILED  "a terminal is required to read the password"
  #   sudo -A /usr/bin/true     SUCCESS
  #
  # sudo(8) describes the sudo.conf askpass path underneath the -A option, and
  # that is precisely how it behaves: the helper is consulted only when -A is
  # passed, NOT merely because no terminal is available. Homebrew starts its
  # installer as `sudo -E PATH=... --`, with no -A, so it never reaches this.
  #
  # What it does buy: any `sudo -A` works without the caller having exported
  # SUDO_ASKPASS first. Small, real, and unrelated to Homebrew.
  #
  # The remaining route to unattended cask installs is a NOPASSWD rule over
  # /opt/homebrew/Caskroom, a USER-WRITABLE path — which would let anything able
  # to write there execute as root. That is not a trade worth making for one
  # application; install such casks from a real terminal instead.
  #
  # This grants nothing. sudo still demands the correct password; it only
  # changes where the prompt is drawn when there is no terminal to draw it in.
  environment.etc."sudo.conf".text = ''
    # Path to askpass helper program
    Path askpass ${askpass}
  '';

  # Passwordless sudo for EXACTLY ONE command: activating this configuration.
  #
  # Why: every rebuild raised a password dialog, which made agent-driven
  # activation stall on a human at the machine (requested removed 2026-08-14).
  #
  # The tradeoff, stated plainly: this account's darwin-rebuild applies a
  # configuration the same account can edit, so NOPASSWD here is
  # root-equivalent for the account. The password prompt was never a real
  # boundary against that — the account already owns the flake — it was only
  # a consent tap. The consent trail is the git history instead: the
  # nix-only-guard hook forces every machine change through this repository,
  # and activation without a declared change is a no-op.
  #
  # Scope: the stable /run/current-system symlink path only, so ad-hoc sudo
  # for anything else still prompts. SETENV because scripts/rebuild.sh passes
  # NIX_CONFIG_LOCAL via --preserve-env — it must NOT wrap the command in
  # `env`, or sudoers matches `env` (not darwin-rebuild) and prompts anyway,
  # which is exactly what the first version of this rule got wrong. The FIRST switch on a wiped machine
  # (before any generation exists) still asks for the password once — the
  # rule cannot predate the system it is part of.
  security.sudo.extraConfig = ''
    ${local.user} ALL=(root) NOPASSWD:SETENV: /run/current-system/sw/bin/darwin-rebuild
  '';
}
