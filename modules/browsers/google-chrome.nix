{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      home-packages-gui = lib.optional pkgs.stdenv.isLinux pkgs.google-chrome |> lib.mkOrder 2500;
    };

  nixpkgs.allowUnfreePackages = [ "google-chrome" ];

  # flake.modules.homeManager.gui =
  #   { pkgs, ... }:
  #   {
  #     home.packages = lib.optional pkgs.stdenv.isLinux pkgs.google-chrome;
  #   };
}
