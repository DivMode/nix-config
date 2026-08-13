{ local, ... }:
{
  imports = [ ../modules/home ];

  home.username = local.user;
  home.homeDirectory = local.homeDirectory;
}
