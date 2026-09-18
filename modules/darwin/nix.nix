{ inputs, ... }:
{
  nix.channel.enable = false;
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # numtide's binary cache, for the packages taken from the llm-agents input
  # (Herdr, ccstatusline, the Claude Code build recipe's dependencies). That
  # flake declares this cache and key in its own `nixConfig`, but a flake's
  # nixConfig is ignored for a non-trusted user, so without this every one of
  # those packages was compiled on this Mac — Herdr alone is a Rust build plus
  # a vendored Zig library, minutes of compile on each version change.
  # Measured 2026-09-17: only cache.nixos.org was configured, and
  # cache.numtide.com already answered 200 for the narinfo of llm-agents'
  # herdr-0.9.1 aarch64-darwin output.
  #
  # The cache only ever hits because llm-agents' nixpkgs input is NOT made to
  # follow this repository's: a store path is a hash of its inputs, so
  # `follows` would produce paths numtide never built. Do not add it.
  #
  # Trust: binaries are accepted only when signed by the key below, which is
  # the key the llm-agents flake itself publishes. This repository already
  # runs that flake's build recipes; trusting its signed builds of the same
  # recipes adds the cache operator, not a new author.
  nix.settings.extra-substituters = [ "https://cache.numtide.com" ];
  nix.settings.extra-trusted-public-keys = [
    "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
  ];

  nix.registry.nixpkgs.flake = inputs.nixpkgs;

  # Garbage collection was never declared, so nothing ever removed anything:
  # measured 2026-09-02, /nix/store held 50.7 GB with 134 system generations
  # retained since the 2026-08-13 reset and 31.2 GB of dead paths
  # (`nix-store --gc --print-dead | xargs du -sck`), on an internal volume that
  # had 1.0 GB free. Weekly collection with a 7-day generation window keeps a
  # week of rollback targets and bounds the store; store optimisation
  # hard-links identical files the way `auto-optimise-store` would.
  nix.gc = {
    automatic = true;
    interval = {
      Weekday = 0;
      Hour = 4;
      Minute = 0;
    };
    options = "--delete-older-than 7d";
  };
  nix.optimise.automatic = true;
}
