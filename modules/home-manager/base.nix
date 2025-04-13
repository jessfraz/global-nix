{ config, ... }:
{
  flake.modules.homeManager.base =
    { pkgs, ... }:
    {
      home = {
        username = config.flake.meta.owner.username;
        homeDirectory = "${
          if pkgs.stdenv.isDarwin then "/Users" else "/home"
        }/${config.flake.meta.owner.username}";
      };
      # Let Home Manager install and manage itself.
      programs.home-manager.enable = true;
      #systemd.user.startServices = "sd-switch";
    };
}
