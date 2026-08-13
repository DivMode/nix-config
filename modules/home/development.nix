{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) system;

  # Claude Code comes from the llm-agents flake rather than the Homebrew cask.
  # Both deliver the same signed vendor binary, but the cask lags the release
  # stream badly: on 2026-08-13 the newest homebrew-cask commit still described
  # 2.1.223 while upstream was on 2.1.231. Since the tap is a pinned flake
  # input, no lock update could close that gap. See ../../docs/operations/rebuild.md.
  claudeCode = inputs.llm-agents.packages.${system}.claude-code;

in
{
  options.nixConfig.claudeCode.package = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    default = claudeCode;
    description = ''
      The Claude Code package this configuration uses. Declared here because
      this module owns portable developer tooling, but INSTALLED by
      `programs.claude-code` in ../ai, which wraps it with `--plugin-dir` to
      load plugins. Only one of them may install it, or they collide on
      bin/claude.
    '';
  };

  config = {
    # Portable workstation tools come from the flake-declared nixpkgs input. Git and Zsh
    # are installed by their Home Manager program modules in default.nix.
    home.packages =
      (with pkgs; [
        gh
        fd
        jq
        just
        ripgrep
        mise
        uv
        rustup
        # Package manager and runtime for repositories that declare it in
        # `packageManager`. It was previously a global install, so nothing
        # restored it when this machine was rebuilt and every task that shells
        # out to `bun` failed with "command not found". Declared here for the
        # same reason as everything else: it comes back with the machine.
        #
        # nixpkgs rather than Homebrew. This is a portable CLI, and Homebrew in
        # this configuration owns only native and vendor casks — a formula needs
        # a documented nixpkgs incompatibility, which trailing the latest
        # release by a single patch version is not.
        bun
        # macOS ships no `flock`; it is a util-linux tool. Deploy scripts that
        # serialise themselves with a lock file need it, and without it they do
        # not fail cleanly — the one here reported a two-hour lock timeout,
        # while the actual error was `flock: command not found` on the line
        # below it. This is the standalone BSD-compatible implementation rather
        # than util-linux, which exists mainly for Linux.
        flock
        kubectl
        pulumi
        crane
        # The minimal build retains the GDAL/OGR command suite plus VRT, WebP,
        # SQLite/MBTiles, and projection support without unrelated cloud drivers.
        gdalMinimal
        pmtiles
      ])
      ++ [
        inputs.herdr.packages.${system}.default
      ];

    programs.zsh.initContent = lib.mkAfter ''
      eval "$(${lib.getExe pkgs.mise} activate zsh)"
    '';

    # This is a public fallback policy, not a project lock. Exact project runtime
    # versions belong in each project's repository.
    xdg.configFile."mise/config.toml".text = ''
      [tools]
      node = "24"
    '';
  };
}
