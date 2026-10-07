# Herdr Server.app: a bundled, resident parent for `herdr server`, so macOS can
# grant Local Network access to everything running in Herdr panes.
#
# The problem (herdrdev/herdr#808, still open with no maintainer response on
# 2026-10-06): macOS charges a process's Local Network access to its
# "responsible process", fixed at spawn and inherited from the parent. Herdr's
# server is started by whichever Ghostty first ran `herdr`, and outlives it.
# When that Ghostty quits, attribution reverts to the server itself — a bare,
# ad-hoc-signed Mach-O with no bundle id — which can never be granted, so every
# non-Apple program in every pane gets EHOSTUNREACH on the LAN. Measured here
# on 2026-10-06: responsibility_get_pid_responsible_for_pid returned the Herdr
# server's own pid, Python got "No route to host" to 1Password Connect, and the
# Connect-backed git signer and local.nix backup failed from every pane after
# a Ghostty restart.
#
# The fix is drod3763/herdr-server-app (MIT), the most complete of the
# community workarounds on #808: a small C launcher inside an app bundle that
# spawns `herdr server` as a CHILD and stays alive as its responsible parent,
# respawns it, and stands by (instead of racing) when a server is already on
# the socket. It is built here from its pinned source rather than installed
# from its cask, whose ad-hoc, unnotarized release loses the Local Network
# grant on every upgrade and has to have its quarantine stripped.
#
# The grant binds to the bundle's code signature. So the bundle is installed
# into ~/Applications and signed there with macOS's own codesign only when the
# pinned source changes — never because Herdr, nixpkgs or the compiler moved —
# and the first LAN connection from a pane prompts once for "Herdr Server".
{
  config,
  lib,
  pkgs,
  ...
}:
let
  rev = "4a6107ab5b45e457ac3edd8d23c3a6b5e8b4d38d";
  version = "0.1.0";

  launcherApp = pkgs.stdenv.mkDerivation {
    pname = "herdr-server-app";
    inherit version;
    src = pkgs.fetchFromGitHub {
      owner = "drod3763";
      repo = "herdr-server-app";
      inherit rev;
      hash = "sha256-tp5EGnZTGzOPoD+XJoely3mROydB8YrhNIiUd1hHJ04=";
    };
    # Upstream's Makefile, minus `codesign` (done at activation, see above)
    # and the universal build: this Mac is arm64 only.
    buildPhase = ''
      runHook preBuild
      $CC -O2 -Wall -Wextra -mmacosx-version-min=13.0 \
        -DHERDR_SERVER_VERSION='"${version}"' \
        -o herdr-server-launcher launcher/launcher.c
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      app="$out/Applications/Herdr Server.app/Contents"
      mkdir -p "$app/MacOS" "$app/Resources"
      install -m 0755 herdr-server-launcher "$app/MacOS/herdr-server-launcher"
      sed 's/__VERSION__/${version}/g' launcher/Info.plist > "$app/Info.plist"
      printf 'APPL????' > "$app/PkgInfo"
      runHook postInstall
    '';
  };

  installedApp = "${config.home.homeDirectory}/Applications/Herdr Server.app";
  launcher = "${installedApp}/Contents/MacOS/herdr-server-launcher";
  # What the installed bundle was built from. Changing only when `rev` does is
  # what keeps the signature, and so the Local Network grant, across rebuilds.
  marker = "${config.xdg.stateHome}/herdr-server-app/installed-rev";
in
{
  # Before setupLaunchAgents, so the agent below never starts a missing bundle.
  home.activation.installHerdrServerApp =
    lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "writeBoundary" ]
      ''
        if [[ -d ${lib.escapeShellArg installedApp} ]] \
          && [[ "$(cat ${lib.escapeShellArg marker} 2>/dev/null)" == ${lib.escapeShellArg rev} ]]; then
          verboseEcho "Herdr Server.app is current; leaving its signature and Local Network grant alone"
        elif [[ -d ${lib.escapeShellArg installedApp} && ! -f ${lib.escapeShellArg marker} ]]; then
          errorEcho "Refusing to replace ${installedApp}: it was not installed by this configuration."
          errorEcho "Remove it by hand if it is not wanted, then rebuild."
          exit 1
        else
          run mkdir -p "$(dirname ${lib.escapeShellArg marker})" ${lib.escapeShellArg "${config.home.homeDirectory}/Applications"}
          run rm -rf ${lib.escapeShellArg installedApp}
          run /usr/bin/ditto ${lib.escapeShellArg "${launcherApp}/Applications/Herdr Server.app"} ${lib.escapeShellArg installedApp}
          run /bin/chmod -R u+w ${lib.escapeShellArg installedApp}
          run /usr/bin/codesign --force --sign - --timestamp=none ${lib.escapeShellArg installedApp}
          run /usr/bin/codesign --verify --strict ${lib.escapeShellArg installedApp}
          if [[ ! -v DRY_RUN ]]; then
            printf '%s\n' ${lib.escapeShellArg rev} > ${lib.escapeShellArg marker}
          fi
          # Full Disk Access is granted to the app too. Its new ad-hoc
          # signature may not carry the earlier grant (unverified: no rev bump
          # has happened since the grant), so the warning asks for a check.
          warnEcho "Installed Herdr Server.app ${version}. Allow \"Herdr Server\" when macOS asks about the local network, and check it is still enabled under Privacy & Security > Full Disk Access."
        fi
      '';

  # Upstream's documented LaunchAgent. KeepAlive restarts the launcher, which
  # restarts the server; Aqua keeps it to the logged-in GUI session, where the
  # Local Network prompt can be shown. If a server is already running (for
  # example one a Ghostty started), the launcher stands by until it exits.
  launchd.agents.herdr-server = {
    enable = true;
    config = {
      ProgramArguments = [ launcher ];
      EnvironmentVariables.HERDR_SERVER_BIN = "${config.home.profileDirectory}/bin/herdr";
      RunAtLoad = true;
      KeepAlive = true;
      LimitLoadToSessionType = "Aqua";
      ProcessType = "Interactive";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/herdr-server.log";
    };
  };

  # Home Manager loads an agent only when its plist file changes
  # (setupLaunchAgents: `cmp -s` → "already up-to-date"); it never checks that
  # launchd actually has the agent. On 2026-10-06 the agent was booted out at
  # 02:06:57 with its plist left in place, so every later rebuild skipped it
  # and Herdr silently fell back to a Ghostty-started server. This loads it
  # when the plist is there but launchd has no such job. It never touches a
  # loaded agent, so it restarts nothing.
  home.activation.ensureHerdrServerAgentLoaded =
    let
      label = config.launchd.agents.herdr-server.config.Label;
      plist = "${config.home.homeDirectory}/Library/LaunchAgents/${label}.plist";
    in
    lib.hm.dag.entryAfter [ "setupLaunchAgents" ] ''
      if [[ -f ${lib.escapeShellArg plist} ]] \
        && ! /bin/launchctl print "gui/$UID/${label}" >/dev/null 2>&1; then
        warnEcho "The Herdr Server agent was not loaded; loading it."
        run /bin/launchctl bootstrap "gui/$UID" ${lib.escapeShellArg plist}
      fi
    '';
}
