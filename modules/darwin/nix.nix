{ inputs, ... }:
{
  nix.channel.enable = false;
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  nix.registry.nixpkgs.flake = inputs.nixpkgs;

  # Garbage collection was never declared, so nothing ever removed anything:
  # measured 2026-09-02, /nix/store held 50.7 GB with 134 system generations
  # retained since the 2026-08-13 reset and 31.2 GB of dead paths
  # (`nix-store --gc --print-dead | xargs du -sck`), on an internal volume that
  # had 1.0 GB free. Weekly collection with a 14-day generation window keeps two
  # weeks of rollback targets and bounds the store; store optimisation
  # hard-links identical files the way `auto-optimise-store` would.
  nix.gc = {
    automatic = true;
    interval = {
      Weekday = 0;
      Hour = 4;
      Minute = 0;
    };
    options = "--delete-older-than 14d";
  };
  nix.optimise.automatic = true;
}
