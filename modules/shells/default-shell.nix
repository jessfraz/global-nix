{ config, lib, ... }:
let
  module =
    { pkgs, ... }:
    {
      users.users.${config.flake.meta.owner.username}.shell = pkgs.bash;
    };
in
{
  flake.modules = {
    nixos.desktop = module;
    darwin.base = module;
    homeManager.gui = {
      programs.ghostty.settings.command = "/etc/profiles/per-user/${config.flake.meta.owner.username}/bin/bash";
      # SUGGESTION
      #programs.ghostty.settings.command = lib.getExe pkgs.bash;
    };
  };
}
