{
  lib,
  local,
  pkgs,
  ...
}:
let
  # Xcode's Mac App Store id. `mas lookup 497799835` answered "Xcode 27.1,
  # By: Apple Inc." on 2026-10-17.
  xcodeId = "497799835";
  xcode = "/Applications/Xcode.app";
  developer = "${xcode}/Contents/Developer";

  # mas must run inside the signed-in user's GUI session: the App Store
  # download daemons answer that session, not root's (mas-cli/mas#1221, where
  # every masApps install failed under activation but worked from a terminal).
  # Same construction as dock.nix.
  asUser = ''launchctl asuser "$(id -u -- ${lib.escapeShellArg local.user})" sudo --set-home --user=${lib.escapeShellArg local.user} --'';
in
{
  # Xcode, for iOS development, from the Mac App Store.
  #
  # Why this module and not `homebrew.masApps`:
  #
  # - masApps goes through `brew bundle`, which installs Homebrew's `mas`
  #   formula when it is missing. Formulae are reserved for nixpkgs gaps
  #   (homebrew.nix), and nixpkgs has mas.
  # - With `onActivation.upgrade = true`, brew bundle also upgrades outdated
  #   App Store apps. A pending Xcode update would then download about 3 GB in
  #   the middle of a rebuild, and a failed mas upgrade makes brew bundle exit
  #   non-zero, which aborts the switch half-applied (see the SUDO_ASKPASS note
  #   in homebrew.nix). mas-cli/mas#1221 reports exactly that failure while an
  #   App Store update is pending.
  #
  # nix-darwin's own `programs.mas` module (PR #1668, merged 2026-07-15) is the
  # same shape as this one, but it is only on master; the pinned
  # nix-darwin-26.05 branch does not have modules/programs/mas.nix. Replace this
  # file with it when the pin moves to a release that carries it.
  #
  # Install once, then leave updates to the App Store, like Chrome and ChatGPT
  # in homebrew.nix: there is no `mas update` here, so a rebuild never upgrades
  # Xcode. The App Store does not let a version be pinned, and App Store
  # submissions require a recent SDK anyway.
  #
  # mas 6 installs as root: since Apple's CVE-2025-43411 fix it hands the
  # package to /usr/sbin/installer, re-executing itself through
  # `sudo MAS_NO_AUTO_INDEX=1 mas ...` (Sources/mas/Utilities/Sudo.swift at
  # v6.0.1). The NOPASSWD:SETENV entry in sudo.nix lets that run unattended.
  environment.systemPackages = [ pkgs.mas ];

  # The asc CLI (./homebrew.nix) sends command telemetry by default and, once a
  # day, runs `npx skills check` in the background. Skills here are vendored
  # and pinned in each project, so that check only reports noise.
  environment.variables = {
    ASC_TELEMETRY_DISABLED = "1";
    ASC_SKILLS_AUTO_CHECK = "0";
  };

  # postActivation runs after Homebrew in the pinned activation-scripts.nix.
  system.activationScripts.postActivation.text = lib.mkAfter ''
    if [ ! -d ${xcode} ]; then
      echo >&2 "installing Xcode from the Mac App Store (about 3 GB)..."
      # A missing App Store sign-in is something only the account owner can
      # fix, so it warns rather than failing every unrelated rebuild.
      ${asUser} ${lib.getExe pkgs.mas} install ${xcodeId} \
        || echo >&2 "warning: Xcode was not installed; sign in to the App Store and rebuild"
    fi

    if [ -d ${xcode} ]; then
      if [ "$(/usr/bin/xcode-select --print-path 2>/dev/null)" != ${developer} ]; then
        echo >&2 "selecting ${xcode}..."
        /usr/bin/xcode-select --switch ${developer}
      fi
      # Xcode refuses xcodebuild and the toolchain until its license is
      # accepted, and an App Store update can ask again.
      if ! /usr/bin/xcodebuild -license check >/dev/null 2>&1; then
        echo >&2 "accepting the Xcode license..."
        /usr/bin/xcodebuild -license accept
      fi
      # The system packages (MobileDevice and friends) Xcode otherwise installs
      # behind an admin prompt on first launch.
      if ! /usr/bin/xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
        echo >&2 "running Xcode first-launch tasks..."
        /usr/bin/xcodebuild -runFirstLaunch
      fi
      # Xcode ships the iOS SDK but not the iOS Simulator runtime: after the
      # 27.1 install on 2026-10-17, `xcodebuild -showsdks` listed
      # iphonesimulator27.1 while `simctl list runtimes` was empty. Without it
      # nothing runs in the simulator. The runtime is about 8 GB, once.
      if ! ${asUser} /usr/bin/xcrun simctl list runtimes iOS 2>/dev/null | grep -q '^iOS '; then
        echo >&2 "downloading the iOS Simulator runtime (about 8 GB)..."
        /usr/bin/xcodebuild -downloadPlatform iOS
      fi
    fi
  '';
}
