{
  pkgs,
  lib,
  inputs,
  ...
}: let
  homeDir =
    if pkgs.stdenv.isLinux
    then "/home/jessfraz"
    else "/Users/jessfraz";
in {
  home = {
    username = "jessfraz";
    homeDirectory = lib.mkForce homeDir;

    # This value determines the Home Manager release that your configuration is
    # compatible with. This helps avoid breakage when a new Home Manager release
    # introduces backwards incompatible changes.
    #
    # You should not change this value, even if you update Home Manager. If you do
    # want to update the value, then make sure to first check the Home Manager
    # release notes.
    stateVersion = "25.05"; # Please read the comment before changing.
  };

  programs = {
    # Let Home Manager install and manage itself.
    home-manager.enable = true;
    git.enable = true;
    bash.enable = true;
  };

}
