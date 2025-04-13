{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      home-packages-gui = lib.mkMerge [
        (lib.mkOrder 500 [ pkgs.coreutils ])
        (lib.mkOrder 1300 [ pkgs.gnused ])
        (lib.mkOrder 2200 [ pkgs.watch ])
        (lib.mkOrder 1100 [ pkgs.gnumake ])
        (lib.mkOrder 1500 [ pkgs.just ])
      ];
    };

  # flake.modules.homeManager.base =
  #   { pkgs, ... }:
  #   {
  #     home.packages = with pkgs; [
  #       coreutils
  #       gnused
  #       watch
  #       gnumake
  #       just
  #     ];
  #   };
}
