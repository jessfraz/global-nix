{ lib, ... }:
{
  flake.modules = {
    homeManager.gui =
      { pkgs, ... }:
      {
        targets.darwin.defaults = lib.mkIf pkgs.stdenv.isDarwin {
          "com.apple.dock" = {
            autohide = true;
            orientation = "bottom";
            tilesize = 44;
          };
          "com.apple.finder" = {
            # Show hidden files in Finder.
            AppleShowAllFiles = true;
            # Automatically delete items from trash after 30 days.
            FXRemoveOldTrashItems = true;
            # Show the path bar at the bottom of a Finder window.
            ShowPathbar = true;
            # Show the status bar at the bottom of a Finder window.
            ShowStatusBar = true;
          };
        };
      };

    darwin.gui.system.defaults.dock = {
      # Auto-hide the Dock.
      autohide = true;
      # Enable highlight hover effect for the grid view of a stack in the Dock.
      mouse-over-hilite-stack = true;

      orientation = "bottom";
      show-recents = false;
      tilesize = 44;
      #  Magnify icon on hover.
      magnification = true;
      # Magnified icon size on hover.
      largesize = 48;

      # Enable spring loading for all Dock items.
      enable-spring-load-actions-on-all-items = true;

      # Set the minimize/maximize window effect.
      mineffect = "genie";
    };
  };
}
