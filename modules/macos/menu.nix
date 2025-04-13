{ lib, ... }:
{
  flake.modules.homeManager.gui =
    { pkgs, ... }:
    {
      targets.darwin.defaults."com.apple.Safari".IncludeDevelopMenu = lib.mkIf pkgs.stdenv.isDarwin true;
    };
}
