# oMLX, the MLX inference server for Apple Silicon (github.com/jundot/omlx).
#
# The app is NOT a Nix-store application, deliberately. Its in-app updater
# replaces the live bundle by atomically swapping it with a staged copy in the
# same parent directory (apps/omlx-mac/Sources/Updater/UpdateInstaller.swift,
# `atomicSwap`), which a read-only store path cannot take. Nor is it built from
# source: v0.7.2 pins mlx==0.32.4, transformers>=5.14 and five MLX libraries at
# git commits (pyproject.toml), against nixpkgs' mlx 0.31.2 and transformers
# 5.5.4 on 2026-10-28, and its Homebrew formula is a pip venv on a second
# Python. The release DMG bundles its own Python and precompiled Metal kernels.
# So Nix pins that DMG by hash and installs the app once, where absent; from
# then on the app owns its own updates, the way Claude Code's native install
# does (./development.nix). The seed only matters on a fresh machine and is
# bumped by hand.
{
  config,
  lib,
  local,
  pkgs,
  ...
}:
let
  appPath = "${config.home.homeDirectory}/Applications/oMLX.app";

  # The op:// reference of the one oMLX API key, from the ignored local.nix.
  apiKeyReference = local.onePassword.omlxApiKeyReference or null;

  # oMLX's settings, as its first-run window would write them. The app shows
  # that window only while <base>/settings.json is absent
  # (apps/omlx-mac/Sources/App/AppDelegate.swift, `hasExistingConfig`), and
  # its own save sets exactly these keys and keeps every other key verbatim
  # (Sources/Config/AppConfig.swift, `save`). So these are merged into the
  # file, and the server keeps owning the rest of it.
  settingsPath = "${config.home.homeDirectory}/.omlx/settings.json";
  modelsDir = "${config.home.homeDirectory}/.omlx/models";

  # The key lives only in 1Password. Activation never reads 1Password
  # (./secrets.nix), and oMLX cannot read Connect itself, so this runs as an
  # agent at login and whenever its plist changes: it reads the key through
  # Connect, merges it with the declared settings, and writes the file only
  # when the result differs, with the 0600 mode the server itself uses.
  writeSettings = pkgs.writeShellApplication {
    name = "omlx-write-settings";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      settings=${lib.escapeShellArg settingsPath}
      key="$(${pkgs.python3}/bin/python3 ${../../scripts}/onepassword-connect-read.py \
        ${lib.escapeShellArg config.nixConfig.secrets.onePassword.connect.envPath} \
        ${lib.escapeShellArg (toString apiKeyReference)})"
      if [[ "$key" != sk-omlx-* ]]; then
        echo "the oMLX API key read from 1Password is not an sk-omlx- key" >&2
        exit 1
      fi

      mkdir -p "$(dirname "$settings")" ${lib.escapeShellArg modelsDir}
      current='{}'
      if [[ -e "$settings" ]]; then
        current="$(cat "$settings")"
      fi
      umask 077
      next="$(mktemp "$settings.XXXXXX")"
      # The key reaches jq through a file descriptor, never argv.
      jq --rawfile key <(printf '%s' "$key") \
        --arg dir ${lib.escapeShellArg modelsDir} '
          .version //= "1.0"
          | .server.host = "127.0.0.1"
          | .server.port = 8000
          | .server.auto_start_on_launch = true
          | .auth.api_key = $key
          | .model.model_dirs = [$dir]
          | .model.model_dir = $dir
        ' <<<"$current" > "$next"
      # Compared as canonical JSON: the server re-saves the file in its own
      # layout, and a byte comparison rewrote it after every such save
      # (2026-10-28) though nothing in it had changed.
      if [[ -e "$settings" ]] && [[ "$(jq -S . "$next")" == "$(jq -S . "$settings")" ]]; then
        rm "$next"
      else
        mv "$next" "$settings"
        echo "$(date -u +%FT%TZ) wrote $settings"
      fi
    '';
  };

  # The macOS 26/27 build; the release also carries a separate Sequoia DMG.
  # The hash equals the sha256 GitHub publishes for the asset.
  seed = pkgs.stdenvNoCC.mkDerivation rec {
    pname = "omlx-app-seed";
    version = "0.7.2";
    src = pkgs.fetchurl {
      url = "https://github.com/jundot/omlx/releases/download/v${version}/oMLX-${version}-macos26-27.dmg";
      hash = "sha256-DO3a96iQHUQLyIrLPgM7KUrU0bRbV9AvtzgzyDnScLk=";
    };
    nativeBuildInputs = [ pkgs._7zz ];
    # Unpacked at build time because mounting is not available: hdiutil
    # refused to attach the image from an agent session ("attach failed -
    # Permission denied", 2026-10-28, with and without the tool sandbox).
    unpackPhase = "7zz x -snld $src";
    installPhase = "mkdir -p $out && cp -R oMLX.app $out/";
    # The bundle is signed, so no file in it may change. stdenv's
    # updateAutotoolsGnuConfigScriptsPhase replaced two sealed files in the
    # bundled Python (tvm_ffi/3rdparty/libbacktrace/config.guess and
    # config.sub) with gnu-config's copies, and codesign reported both "file
    # modified" (build log and verification, 2026-10-28).
    dontUpdateAutotoolsGnuConfigScripts = true;
    dontFixup = true;
  };

  # Nine shell-script launchers in the bundle (Contents/MacOS/omlx-cli among
  # them) carry their code signatures as com.apple.cs.* extended attributes.
  # The store cannot hold xattrs, so 7zz writes each one as a sidecar file
  # named `<file>:<attribute>`, and the unpacked bundle fails
  # `codesign --verify --deep --strict` ("code object is not signed at all,
  # In subcomponent: .../Contents/MacOS/omlx-cluster-python", 2026-10-28).
  # This copies the bundle out of the store, turns every sidecar back into
  # the attribute it was, and installs the app only if its signature then
  # verifies, so a broken copy never lands at the real path.
  installApp = pkgs.writeShellApplication {
    name = "omlx-install-app";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
    ];
    text = ''
      app=${lib.escapeShellArg appPath}
      stage="$(dirname "$app")/.oMLX.app.nix-config"
      mkdir -p "$(dirname "$app")"
      # Only ever this script's own unfinished copy from an earlier failure.
      rm -rf "$stage"
      /usr/bin/ditto ${seed}/oMLX.app "$stage"
      # Store copies are read-only, and the updater must be able to remove
      # the bundle it swaps out.
      chmod -R u+w "$stage"
      find "$stage" -name '*:com.apple.cs.*' -print0 |
        while IFS= read -r -d "" sidecar; do
          target="''${sidecar%%:com.apple.cs.*}"
          attribute="''${sidecar#"$target":}"
          /usr/bin/xattr -wx "$attribute" "$(od -An -v -tx1 "$sidecar" | tr -d ' \n')" "$target"
          rm "$sidecar"
        done
      /usr/bin/codesign --verify --deep --strict "$stage"
      mv "$stage" "$app"
    '';
  };

in
{
  # Installs the app only when nothing is at the path. An existing app,
  # including one the updater has moved past this seed, is left untouched.
  home.activation.installOmlx = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    app=${lib.escapeShellArg appPath}
    if [[ -L "$app" || ( -e "$app" && ! -d "$app" ) ]]; then
      echo "Cannot install oMLX at $app because a symlink or non-directory already exists" >&2
      exit 1
    fi
    if [[ ! -e "$app" ]]; then
      run ${lib.getExe installApp}
    fi
  '';

  # `omlx` in the terminal. On launch the app writes its CLI shim to
  # ~/.omlx/bin/omlx and, when that folder is not on PATH, asks to append a
  # PATH block to the user's shell file. It skips that prompt when ~/.zshrc,
  # ~/.zprofile or ~/.zshenv contains its begin marker: "The shim marker in a
  # shell file is the only signal that 'Update Shell File' already ran"
  # (apps/omlx-mac/Sources/Config/ShellEnvWriter.swift). Of those, only
  # ~/.zshenv exists here: the Home Manager stub that sources ZDOTDIR's
  # .zshenv. That stub is skipped by every shell started from another one,
  # because ZDOTDIR is exported (`zsh` from a terminal did not find `omlx`
  # with the PATH line in the stub, 2026-10-28). So the PATH entry is in
  # ZDOTDIR's .zshenv, which every zsh reads, and the stub carries only the
  # markers the app looks for, so it never edits a shell file. Appended, so
  # nothing on this PATH is shadowed.
  programs.zsh.envExtra = ''
    if [[ ":$PATH:" != *":$HOME/.omlx/bin:"* ]]; then
      path+=("$HOME/.omlx/bin")
    fi
  '';
  home.file.".zshenv".text = lib.mkAfter ''
    # oMLX: CLI shim path begin
    # The PATH entry is in ZDOTDIR's .zshenv (modules/home/omlx.nix).
    # oMLX: CLI shim path end
  '';

  # A failed run (Connect unreachable, no network at login) retries after
  # the throttle interval; a successful one exits 0 and stays down.
  launchd.agents.omlx-settings = lib.mkIf (apiKeyReference != null) {
    enable = true;
    config = {
      ProgramArguments = [ (lib.getExe writeSettings) ];
      RunAtLoad = true;
      KeepAlive.SuccessfulExit = false;
      ThrottleInterval = 60;
      ProcessType = "Background";
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/omlx-settings.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/omlx-settings.log";
    };
  };
}
