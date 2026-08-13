{
  inputs,
  lib,
  pkgs,
  ...
}:
{
  # Portable workstation tools come from the flake-declared nixpkgs input. Git and Zsh
  # are installed by their Home Manager program modules in default.nix.
  home.packages = with pkgs; [
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
    inputs.herdr.packages.${pkgs.stdenv.hostPlatform.system}.default
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
}
