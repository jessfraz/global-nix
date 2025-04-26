{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      home-packages-gui = lib.mkOrder 2100 [ pkgs.uv ];
    };

  # flake.modules.homeManager.base =
  #   { pkgs, ... }:
  #   {
  #     home.packages = [ pkgs.uv ];
  #   };
}
