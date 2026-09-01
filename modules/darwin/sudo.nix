{
  local,
  sudoAskpass,
  ...
}:
{
  # An askpass helper sudo can find without the environment.
  #
  # READ THIS BEFORE REACHING FOR IT AGAIN. On its own it does NOT make
  # unattended cask installs work, which is what it was added for on
  # 2026-08-21. Measured that day, in a shell with no controlling terminal:
  #
  #   sudo /usr/bin/true        FAILED  "a terminal is required to read the password"
  #   sudo -A /usr/bin/true     SUCCESS
  #
  # sudo(8) describes the sudo.conf askpass path underneath the -A option, and
  # that is precisely how it behaves: the helper is consulted only when -A is
  # passed, NOT merely because no terminal is available.
  #
  # The old note here stopped at "Homebrew starts its installer as
  # `sudo -E PATH=... --`, with no -A, so it never reaches this", and concluded
  # the case was closed. It was half the story. Homebrew decides whether to pass
  # -A by looking at its OWN environment — Library/Homebrew/system_command.rb:
  #
  #   askpass_flags = ENV.key?("SUDO_ASKPASS") ? ["-A"] : []
  #
  # so Homebrew omits -A only because SUDO_ASKPASS is absent by the time it
  # runs, stripped by nix-darwin's `env -i` activation shebang and then by
  # `sudo --preserve-env=PATH`. Putting the variable back where Homebrew can see
  # it is therefore enough, and ./homebrew.nix does that through
  # `onActivation.extraEnv`, whose values are written literally into the
  # activation command line rather than inherited. Confirmed on 2026-08-31 by
  # the failure this fixed: adobe-acrobat-pro aborted with
  # `/usr/bin/sudo -u root -E ... -- /usr/sbin/installer`, no -A present.
  #
  # This still grants nothing and still is not unattended: sudo demands the
  # correct password either way. It only decides WHERE the prompt is drawn when
  # there is no terminal to draw it in, which turns a hard activation failure
  # into a dialog somebody can answer. A rebuild that installs or upgrades a
  # pkg cask will block on that dialog.
  #
  # That dialog is then removed by the NOPASSWD rule below, and this paragraph
  # used to say the opposite -- that a NOPASSWD rule reaching a USER-WRITABLE
  # payload path was "not a trade worth making". Read the two together or the
  # file contradicts itself: what was rejected was NOPASSWD over
  # /opt/homebrew/Caskroom, granting root to whatever is written there; what is
  # accepted is NOPASSWD on two fixed root-owned binaries that happen to take
  # their payload from that path. The exposure is real and smaller, and it is
  # argued out where the rule is declared rather than here.
  environment.etc."sudo.conf".text = ''
    # Path to askpass helper program
    Path askpass ${sudoAskpass}
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
  # Homebrew's privileged cask installers, so a rebuild never stops on a dialog.
  #
  # A `pkg` cask — karabiner-elements, adobe-acrobat-pro, logi-options+ — is
  # installed by handing its payload to /usr/sbin/installer as root, and removed
  # with /usr/sbin/pkgutil --forget. Those are nested inside `brew bundle`, so
  # the darwin-rebuild rule below never matched them; before 2026-08-31 they did
  # not prompt only because they FAILED, which is why karabiner-elements sat at
  # 16.1.0 for weeks and tailscale-app's uninstall kept leaving a Caskroom stub.
  # ./homebrew.nix now supplies SUDO_ASKPASS so Homebrew passes sudo's -A, and
  # this rule is what stops that dialog from ever being drawn.
  #
  # Scoped to two commands rather than ALL, chosen deliberately on 2026-08-31.
  # The honest argument for going further is that this account can already reach
  # root without a password — it may edit the flake and run the NOPASSWD
  # darwin-rebuild below — so a blanket rule grants little that is not already
  # reachable. The argument against, which won: darwin-rebuild is a rebuild away
  # and leaves a git trail, whereas NOPASSWD:ALL hands every process running as
  # this user an immediate root primitive with no such trail.
  #
  # The residual cost is stated plainly: a Karabiner UPGRADE also runs the
  # vendor's own uninstall scripts under sudo — remove_files.sh and
  # uninstall_core.sh under /Library/Application Support/org.pqrs — which these
  # two entries do not cover, so a Karabiner version bump still raises one
  # dialog. Both scripts are root:wheel 0755 inside a root-owned directory, so
  # naming them here would be safe if that last prompt becomes annoying.
  #
  # /usr/sbin/installer's payload path IS user-writable (/opt/homebrew/Caskroom),
  # so this does let a process that can write there install a package as root.
  # That is the accepted trade, and it is the reason the rule stops at these two
  # binaries instead of covering every command.
  security.sudo.extraConfig = ''
    ${local.user} ALL=(root) NOPASSWD: /usr/sbin/installer, /usr/sbin/pkgutil
    ${local.user} ALL=(root) NOPASSWD:SETENV: /run/current-system/sw/bin/darwin-rebuild
  '';
}
