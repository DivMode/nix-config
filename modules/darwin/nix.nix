{ inputs, ... }:
{
  nix.channel.enable = false;
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  nix.registry.nixpkgs.flake = inputs.nixpkgs;
}
