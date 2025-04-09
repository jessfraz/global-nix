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
  imports = [
    ./programs/bash.nix
    ./programs/git.nix
    ./programs/gpg.nix
  ];

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
    home-manager = {
      # Let Home Manager install and manage itself.
      enable = true;
    };

    man = {
      enable = true;
    };
  };

  xdg = {
    configFile."ghostty/config".text = ''
      command = "/etc/profiles/per-user/jessfraz/bin/bash"
      font-family = "Hack Nerd Font Mono"
      theme = "Ayu Mirage"
      macos-titlebar-style = tabs
      background-opacity = 0.9
      background-blur-radius = 20
    '';
  };

  fonts.fontconfig.enable = true;
}
