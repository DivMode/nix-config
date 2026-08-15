# Herdr workflow plugins, built into the Nix store.
#
# Herdr's own installer (`herdr plugin install owner/repo`) clones into a
# mutable plugin root and runs the upstream `[[build]]` step there — a network
# fetch or a cargo build, at install time, as your user. That is exactly the
# mutable state this repository exists to avoid, and it is the same argument
# ../ai/default.nix already makes for `claude plugins install`.
#
# So each plugin is assembled here instead: upstream's tree from a pinned tag,
# plus the binary its manifest names, at the relative path the manifest names.
# `herdr plugin link` then registers the read-only store path.
#
# That a read-only root works at all is verified, not assumed. A probe plugin
# added with `nix store add-path` linked cleanly, and invoking its action
# returned `exit_code: 0` with the expected stdout, while Herdr kept its own
# mutable per-plugin state outside the store in
# ~/.config/herdr/plugins/config/<id>/.
#
# The `[[build]]` steps are deliberately NOT reproduced. Three of these
# upstreams build by downloading their own release binary and checking its
# SHA-256; fetching that same asset by hash is the identical artifact with the
# verification moved to evaluation time. Only herdr-spreader publishes no
# binary, so it is the one built from source.
{ lib, pkgs }:
let
  inherit (pkgs) fetchFromGitHub fetchurl runCommand;

  spreaderSrc = fetchFromGitHub {
    owner = "yuk1ty";
    repo = "herdr-spreader";
    rev = "v0.2.0";
    hash = "sha256-Cb/Tbr+HbUl5nfBbYHhjyJq6x5GLSmXimD9jjI8/qGw=";
  };

  # The only plugin here with no published binary, so this is the one place the
  # upstream `cargo build --release` is genuinely reproduced.
  #
  # Upstream's rust-toolchain.toml asks for 1.96.1 and nixpkgs provides 1.95.0.
  # buildRustPackage does not read rust-toolchain.toml, so the pin is inert
  # rather than overridden — and 1.95.0 compiles this crate, verified by
  # building it. Revisit only if a future release actually needs 1.96 features.
  spreaderBinary = pkgs.rustPlatform.buildRustPackage {
    pname = "herdr-spreader";
    version = "0.2.0";
    src = spreaderSrc;
    cargoHash = "sha256-PJYF83XM9WhT2HB4mVOArB2cGE8PYe7A3pvF8TD32q0=";
    # Upstream ships integration tests that drive a live herdr socket, which is
    # not available to a sandboxed build.
    doCheck = false;
  };

  # Assemble a plugin root from an upstream tree plus one executable.
  #
  # `binaryPath` is not a convention this file chooses — it is read out of each
  # upstream's herdr-plugin.toml, which spawns its entry points by relative
  # path from the plugin root. Getting it wrong produces a plugin that links
  # and lists correctly and then fails only when an action is invoked.
  mkPlugin =
    {
      pname,
      version,
      src,
      binaryPath,
      # Shell that leaves the executable at $PWD/herdr-plugin-binary.
      unpackBinary,
    }:
    runCommand "herdr-plugin-${pname}-${version}"
      {
        meta = {
          description = "Herdr plugin ${pname}";
          platforms = lib.platforms.darwin ++ lib.platforms.linux;
        };
      }
      ''
        cp -R ${src} "$out"
        # fetchFromGitHub output is read-only; the copy has to be writable to
        # add the binary to it.
        chmod -R u+w "$out"

        ${unpackBinary}

        install -Dm0555 herdr-plugin-binary "$out/${binaryPath}"
      '';

  # A bare executable published as a release asset.
  fromRawBinary = url: hash: ''
    cp ${fetchurl { inherit url hash; }} herdr-plugin-binary
    chmod u+w herdr-plugin-binary
  '';

  # An executable inside a release tarball. `member` is its path within the
  # archive, which differs per upstream: a bare file, a file beside a LICENSE,
  # or a file under a versioned directory.
  fromTarball = url: hash: member: ''
    tar -xzf ${fetchurl { inherit url hash; }}
    cp ${lib.escapeShellArg member} herdr-plugin-binary
    chmod u+w herdr-plugin-binary
  '';
in
{
  # A git-aware read-only file viewer in a split pane.
  # Manifest pane command: ["./target/release/herdr-file-viewer"]
  herdr-file-viewer = mkPlugin {
    pname = "herdr-file-viewer";
    version = "1.15.0";
    binaryPath = "target/release/herdr-file-viewer";
    src = fetchFromGitHub {
      owner = "smarzban";
      repo = "herdr-file-viewer";
      rev = "v1.15.0";
      hash = "sha256-tgy5IHCXqDkIojsP9cDyCG/JXStbjdDdDILopa3SkLI=";
    };
    unpackBinary = fromRawBinary "https://github.com/smarzban/herdr-file-viewer/releases/download/v1.15.0/herdr-file-viewer-aarch64-apple-darwin" "sha256-ruju7+cE1TWjWjTD89uLPZF4+bjjRLGSrX8S3m+ntWE=";
  };

  # Review an agent's diff beside the chat and send line comments back.
  # Manifest pane command: ["sh" "-c" "exec \"$HERDR_PLUGIN_ROOT/bin/herdr-reviewr\""]
  herdr-reviewr = mkPlugin {
    pname = "herdr-reviewr";
    version = "0.30.4";
    binaryPath = "bin/herdr-reviewr";
    src = fetchFromGitHub {
      owner = "persiyanov";
      repo = "herdr-reviewr";
      rev = "v0.30.4";
      hash = "sha256-nlFcIqvHOyp4+doZKu9l1eAlGnLzwPifHji9KPMKepo=";
    };
    unpackBinary =
      fromTarball
        "https://github.com/persiyanov/herdr-reviewr/releases/download/v0.30.4/herdr-reviewr-aarch64-apple-darwin.tar.gz"
        "sha256-1scGRzdYHK66eo97YMwUc2fgRmDoZTVtxrZrW+MY0e0="
        "herdr-reviewr";
  };

  # Projects (declarative workspace templates) and Quick Actions.
  # Manifest action command: ["./bin/herdr-plus" "projects"]
  herdr-plus = mkPlugin {
    pname = "herdr-plus";
    version = "0.1.20";
    binaryPath = "bin/herdr-plus";
    src = fetchFromGitHub {
      owner = "cloudmanic";
      repo = "herdr-plus";
      rev = "v0.1.20";
      hash = "sha256-W95USA0EwP5Oml3qb/wkPqRn+yaaevNBhQuyl9pqaxY=";
    };
    unpackBinary =
      fromTarball
        "https://github.com/cloudmanic/herdr-plus/releases/download/v0.1.20/herdr-plus_0.1.20_darwin_arm64.tar.gz"
        "sha256-0rB6eCKTZzj4uOarv+35oceiyH2802YemGeBf1lzh0s="
        "herdr-plus";
  };

  # Fuzzy navigator over workspaces, agents, projects, sessions, directories.
  # Manifest pane command: ["./target/release/herdr-navigator" "ui"]
  herdr-navigator = mkPlugin {
    pname = "herdr-navigator";
    version = "0.3.6";
    binaryPath = "target/release/herdr-navigator";
    src = fetchFromGitHub {
      owner = "thanhdat77";
      repo = "herdr-navigator";
      rev = "v0.3.6";
      hash = "sha256-+xtBu4m2YenFH+W3Sv7atDvcsgChS5mKXgVgKomM768=";
    };
    unpackBinary =
      fromTarball
        "https://github.com/thanhdat77/herdr-navigator/releases/download/v0.3.6/herdr-navigator-macos-aarch64.tar.gz"
        "sha256-kcqJEj/YiupIk9u3JiNl3Rs0v0xgbhgDaB+kesppiGU="
        "herdr-navigator/herdr-navigator";
  };

  # Apply a whole workspace layout — tabs, panes, startup commands — from YAML.
  # Manifest action command: ["./target/release/herdr-spreader" "apply"]
  #
  # The v0.2.0 tag still declares `version = "0.1.0"` in its own manifest;
  # upstream did not bump it. The tag is what this pins, so 0.2.0 is the
  # accurate version here, and Herdr will report 0.1.0 from the manifest.
  herdr-spreader = mkPlugin {
    pname = "herdr-spreader";
    version = "0.2.0";
    binaryPath = "target/release/herdr-spreader";
    src = spreaderSrc;
    unpackBinary = ''
      cp ${spreaderBinary}/bin/herdr-spreader herdr-plugin-binary
      chmod u+w herdr-plugin-binary
    '';
  };
}
