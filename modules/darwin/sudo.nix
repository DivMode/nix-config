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
  # That dialog is then removed by the NOPASSWD entry below. This paragraph
  # used to weigh a scoped entry against a blanket one; the entry is blanket
  # now, and the argument for that lives where it is declared.
  environment.etc."sudo.conf".text = ''
    # Path to askpass helper program
    Path askpass ${sudoAskpass}
  '';

  # Passwordless sudo, to root, for any command this account runs.
  #
  # Two callers depend on it. scripts/rebuild.sh runs darwin-rebuild under
  # `sudo -A --preserve-env=...` (the original 2026-08-14 request: agent-driven
  # activation must not stall on a human at the machine). Homebrew, nested
  # inside that activation, runs every privileged cask step of its own --
  # /usr/sbin/installer for a pkg, and on uninstall or upgrade the vendor's
  # scripts, /bin/launchctl, /usr/sbin/pkgutil, /usr/bin/xargs over /bin/rm and
  # its cask/utils/rmdir.sh, and /bin/rm for a `delete:` stanza. Both callers
  # need SETENV: rebuild.sh passes --preserve-env, and Homebrew's
  # Library/Homebrew/system_command.rb#sudo_prefix always appends -E:
  #
  #   ["/usr/bin/sudo", "-u", "root", "-A", "-E", "--"]
  #
  # Why ALL, when 2026-08-31 deliberately named two binaries instead: that
  # scoped rule never worked, and no scoped rule can. Measured 2026-09-06 while
  # `nixup` upgraded karabiner-elements 16.2.0 -> 16.3.0:
  #
  #   /usr/bin/sudo -u root -A -E -- /usr/sbin/pkgutil --forget org.pqrs.Karabiner-DriverKit-VirtualHIDDevice
  #   sudo: sorry, you are not allowed to preserve the environment
  #
  # sudoers(5) refuses -E unless the matching entry carries the SETENV tag (ALL
  # implies it). The old `NOPASSWD: /usr/sbin/installer, /usr/sbin/pkgutil`
  # entry had no tag, so it matched, won as the last match over the admin
  # group's `(ALL) ALL`, and then rejected the call that the admin entry would
  # have allowed. It was worse than no rule: Homebrew had already run the
  # vendor's uninstall scripts, so the upgrade aborted with
  # Karabiner-Elements.app gone from /Applications and both pkg receipts still
  # registered, and the earlier steps had drawn the password dialog anyway
  # because the vendor scripts were never in the list. The 2026-08-31 commit's
  # "verified" was the sudoers file existing and 16.2.0 being installed -- an
  # install that had gone through the dialog, which is how the admin entry has
  # always behaved.
  #
  # Adding SETENV to that list would not have finished the job either. The
  # scripts under /Library/Application Support/org.pqrs are one cask's; every
  # cask with a sudo script adds a path, so an enumerated list prompts again on
  # the next one. And an entry for /usr/bin/xargs or /bin/rm as root IS an
  # immediate root primitive with no trail, which is exactly the property the
  # 2026-08-31 argument held against ALL. An honest list is ALL with a
  # maintenance burden.
  #
  # The trade, stated plainly: any process running as this account can become
  # root without a password. The account already could -- it edits the flake
  # and activated it under the NOPASSWD darwin-rebuild entry this replaces, and
  # the NOPASSWD /usr/sbin/installer entry took its payload from user-writable
  # /opt/homebrew/Caskroom. The password was a consent tap; the consent trail is
  # git, because the nix-only-guard hook forces every machine change through
  # this repository. The requirement that decided it, from the account's owner
  # on 2026-09-06: `nixup` must never ask for a password.
  #
  # The FIRST switch on a wiped machine still asks once -- this entry cannot
  # predate the system it is part of -- and that one dialog is what the askpass
  # helper above exists for.
  security.sudo.extraConfig = ''
    ${local.user} ALL=(root) NOPASSWD:SETENV: ALL
  '';
}
