{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      home-packages-gui = lib.optional pkgs.stdenv.isLinux pkgs.tailscale |> lib.mkOrder 2700;
    };

  flake.modules = {
    # homeManager.base =
    #   { pkgs, ... }:
    #   {
    #     home.packages = lib.optional pkgs.stdenv.isLinux pkgs.tailscale;
    #   };

    nixos.desktop.services.tailscale = {
      enable = true;

      extraUpFlags = [ "--ssh" ];
    };
  };
}
