{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      home-packages-gui = lib.mkOrder 600 [ pkgs.curl ];
    };

  # flake.modules.homeManager.base =
  #   { pkgs, ... }:
  #   {
  #     home.packages = [ pkgs.curl ];
  #   };
}
