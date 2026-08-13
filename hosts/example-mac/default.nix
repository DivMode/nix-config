{
  inputs,
  local,
  localConfigured,
  ai,
  pkgs,
  ...
}:
{
  assertions = [
    {
      assertion = localConfigured;
      message = "Refusing to build or activate a host without an explicit absolute NIX_CONFIG_LOCAL path and --impure";
    }
  ];

  imports = [
    inputs.home-manager.darwinModules.home-manager
    inputs.nix-homebrew.darwinModules.nix-homebrew
    ../../modules/darwin
  ];

  networking.hostName = local.hostName;
  nixpkgs.hostPlatform = local.system;
  system.primaryUser = local.user;

  users.users.${local.user} = {
    home = local.homeDirectory;
    shell = pkgs.zsh;
  };
  environment.shells = [ pkgs.zsh ];

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = {
      inherit inputs local ai;
    };
    users.${local.user} = import ../../profiles/example-user.nix;
  };
}
