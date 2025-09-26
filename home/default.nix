{
  pkgs,
  lib,
  inputs,
  homeDir,
  username,
  ...
}: let
  ghosttyPkg =
    if pkgs.stdenv.isLinux
    then inputs.ghostty.packages.${pkgs.stdenv.system}.default
    else null; # We install on our own on macOS
in {
  imports = [
    ./programs/bash.nix
    ./programs/git.nix
    ./programs/gpg.nix
    ./programs/starship.nix
  ];

  home = {
    username = username;
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

    ssh = {
      enable = true;
      # Home Manager is deprecating implicit defaults; be explicit.
      enableDefaultConfig = false;
      matchBlocks = {
        "*" = {
          addKeysToAgent = "yes";
        };
      };
    };

    ghostty = {
      enable = true;

      package = ghosttyPkg;

      settings = {
        command = "/etc/profiles/per-user/${username}/bin/bash";
        font-family = "Hack Nerd Font Mono";
        theme = "Ayu Mirage";
        macos-titlebar-style = "tabs";
        background-opacity = 0.9;
        background-blur-radius = 20;
        shell-integration-features = "title,cursor,sudo,ssh-env,ssh-terminfo";
      };

      enableBashIntegration = true;
    };
  };

  fonts.fontconfig.enable = true;
}
