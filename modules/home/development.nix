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

  # The 1Password launcher in secrets.nix installs its own executable named
  # `claude`, wrapping the package below. Installing both would collide on
  # bin/claude, so exactly one of them owns the command.
  claudeCodeIsWrapped = config.nixConfig.secrets.onePassword.enable;
in
{
  options.nixConfig.claudeCode.package = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    default = claudeCode;
    description = ''
      The Claude Code package this configuration installs. Exposed so the
      1Password launcher can wrap this exact build by absolute store path
      rather than resolving `claude` through PATH, which would re-enter the
      wrapper.
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
      ]
      ++ lib.optional (!claudeCodeIsWrapped) claudeCode;

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
