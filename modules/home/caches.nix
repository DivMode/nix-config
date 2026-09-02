{
  config,
  lib,
  local,
  ...
}:
let
  # Where package and tool caches live, from the ignored local.nix (a path on an
  # external volume is machine-specific). Null leaves every cache at its default.
  cacheDirectory = local.cacheDirectory or null;
  enabled = cacheDirectory != null;
  cacheDir = name: "${cacheDirectory}/${name}";
in
{
  # Package managers and browser-automation tools default their caches to the
  # home directory and nothing tells them otherwise. Measured 2026-09-02 on the
  # internal volume: Bun's install cache 7.1 GB, NuGet 7.0 GB, ~/.cache 6.9 GB
  # (Playwright 1.5 GB, Puppeteer 0.5 GB, uv 0.4 GB, project caches), Homebrew's
  # download cache 3.4 GB. Source checkouts already live on the external volume;
  # this points the caches there too, through each tool's documented variable.
  #
  # CARGO_HOME and RUSTUP_HOME move too (4.7 GB measured). cargo, rustc and
  # rustup themselves are the Nix-packaged rustup proxies on PATH, so the bin
  # directory under CARGO_HOME only matters for `cargo install`ed tools, which
  # is why it is appended to the session PATH. Relocating an existing
  # installation empties the toolchain list until the old directories are
  # synced across; do that before deleting them or every cargo gate breaks.
  # Chrome, Codex sessions, and SST's platform cache are application state
  # with no relocation knob.
  #
  # XDG_CACHE_HOME is set through Home Manager's own option so anything that
  # honours the XDG spec (uv, nix's eval cache, most Rust and Python tools)
  # follows without a per-tool variable.
  config = lib.mkIf enabled {
    # Home Manager only EXPORTS XDG_CACHE_HOME when xdg.enable is on; without
    # it, xdg.cacheHome changes where Home Manager's own modules write and
    # nothing else (verified 2026-09-02: the variable was absent from
    # hm-session-vars.sh with only cacheHome set).
    xdg.enable = true;
    xdg.cacheHome = cacheDir "xdg";

    home.sessionVariables = {
      BUN_INSTALL_CACHE_DIR = cacheDir "bun";
      NUGET_PACKAGES = cacheDir "nuget/packages";
      PLAYWRIGHT_BROWSERS_PATH = cacheDir "ms-playwright";
      PUPPETEER_CACHE_DIR = cacheDir "puppeteer";
      UV_CACHE_DIR = cacheDir "uv";
      HOMEBREW_CACHE = cacheDir "homebrew";
      CARGO_HOME = cacheDir "cargo";
      RUSTUP_HOME = cacheDir "rustup";
    };

    home.sessionPath = [ (cacheDir "cargo/bin") ];

    # Same shape as downloads.nix: refuse a symlink or file at the path, and
    # report an unmounted volume as such rather than as a permissions error.
    home.activation.validateCacheDirectory = lib.hm.dag.entryBefore [ "writeBoundary" ] ''
      cacheDirectory=${lib.escapeShellArg cacheDirectory}

      if [[ -L "$cacheDirectory" || ( -e "$cacheDirectory" && ! -d "$cacheDirectory" ) ]]; then
        echo "Cannot create $cacheDirectory because a symlink or non-directory already exists" >&2
        exit 1
      fi

      cacheParent=$(dirname "$cacheDirectory")
      if [[ ! -d "$cacheParent" ]]; then
        echo "Cannot create $cacheDirectory because $cacheParent does not exist; is that volume mounted?" >&2
        exit 1
      fi
    '';

    # `run` preserves Home Manager's dry-run behavior.
    home.activation.ensureCacheDirectories = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run mkdir -p ${
        lib.escapeShellArgs [
          (cacheDir "xdg")
          (cacheDir "bun")
          (cacheDir "nuget/packages")
          (cacheDir "ms-playwright")
          (cacheDir "puppeteer")
          (cacheDir "uv")
          (cacheDir "homebrew")
          (cacheDir "cargo")
          (cacheDir "rustup")
        ]
      }
    '';
  };
}
