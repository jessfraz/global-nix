{ lib, ... }:
{
  flake.modules.homeManager.gui =
    { pkgs, ... }:
    lib.mkIf pkgs.stdenv.isLinux {
      home.pointerCursor = {
        package = pkgs.vanilla-dmz;
        name = "Vanilla-DMZ";
        gtk.enable = true;
      };
    };
}
