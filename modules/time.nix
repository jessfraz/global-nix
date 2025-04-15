{ lib, ... }:
{
  flake.modules =
    let
      timeZone = "America/Los_Angeles";
    in
    {
      nixos.desktop = {
        time = { inherit timeZone; };
        #services.ntpd-rs.enable = true;
      };

      darwin.gui.system.defaults.menuExtraClock.Show24Hour = true;

      homeManager = {
        gui =
          { pkgs, ... }:
          {
            # Show 24-hour clock in menu bar.
            targets.darwin.defaults."com.apple.menuextra.clock".Show24Hour = lib.mkIf pkgs.stdenv.isDarwin true;

            #base.home.sessionVariables.TZ = timeZone;
          };

      };
    };
}
