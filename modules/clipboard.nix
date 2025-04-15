{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      home-packages-gui = lib.optional pkgs.stdenv.isLinux pkgs.xclip |> lib.mkOrder 2800;
    };

  # flake.modules.homeManager.gui =
  #   { pkgs, ... }:
  #   {
  #     home.packages = lib.optional pkgs.stdenv.isLinux pkgs.xclip;
  #   };
}
