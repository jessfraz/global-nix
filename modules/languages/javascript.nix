{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      home-packages-gui = lib.mkMerge [
        (lib.mkOrder 1600 [ pkgs.nodejs ])
        (lib.mkOrder 2300 [ pkgs.yarn ])
      ];
    };

  # flake.modules.homeManager.base =
  #   { pkgs, ... }:
  #   {
  #     home.packages = with pkgs; [
  #       nodejs
  #       yarn
  #     ];
  #   };
}
