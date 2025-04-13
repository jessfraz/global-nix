{ lib, ... }:
{
  flake.modules = {
    # Show battery percentage in menu bar.
    darwin.gui.system.defaults.controlcenter.BatteryShowPercentage = true;

    homeManager.gui =
      { pkgs, ... }:
      {
        # Show battery percentage in menu bar.
        targets.darwin.defaults."com.apple.controlcenter".BatteryShowPercentage =
          lib.mkIf pkgs.stdenv.isDarwin true;
      };
  };
}
