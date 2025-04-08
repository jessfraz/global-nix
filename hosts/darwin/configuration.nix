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

    CustomUserPreferences = {
      "com.apple.finder" = {
        # Show all files.
        AppleShowAllFiles = true;
        ShowPathBar = true;
      };

      "com.apple.dock" = {
        autohide = true; # Auto-hide the Dock
      };

      "com.apple.menuextra.battery" = {
        # Battery percentage in menu bar
        ShowPercent = "YES";
      };

      "com.apple.menuextra.clock" = {
        Show24Hour = true;
      };
    };
  };

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 6;
}
