{
  config,
  pkgs,
  inputs,
  ...
}: {
  # macOS system preferences
  system.defaults = {
    NSGlobalDomain = {
      # Show all the file extensions.
      AppleShowAllExtensions = true;
    };

    dock = {
      enable-spring-load-actions-on-all-items = true;
      mouse-over-hilite-stack = true;

      mineffect = "genie";
      orientation = "left";
      show-recents = false;
      tilesize = 44;
    };

    CustomUserPreferences = {
      "com.apple.finder" = {
        # Show all files.
        AppleShowAllFiles = true;
        ShowPathBar = true;
        FXRemoveOldTrashItems = true;
        ShowStatusBar = true;
      };

      "com.apple.dock" = {
        autohide = true; # Auto-hide the Dock
        magnification = true;
        largesize = 48;
      };

      "com.apple.menuextra.battery" = {
        # Battery percentage in menu bar
        ShowPercent = "YES";
      };

      "com.apple.menuextra.clock" = {
        Show24Hour = true;
      };

      "com.apple.controlcenter" = {
        BatteryShowPercentage = true;
      };
    };
  };

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 6;
}
