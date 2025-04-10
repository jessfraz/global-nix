{...}: {
  # Fix for https://github.com/nix-community/home-manager/issues/5997
  programs.bash.initExtra = ''
    gpgconf --launch gpg-agent
  '';
  programs.bash.sessionVariables = {
    SSH_AUTH_SOCK = "$(gpgconf --list-dirs agent-ssh-socket)";
  };

  targets.darwin.defaults = {
    NSGlobalDomain = {
      # Always show file extensions in Finder.
      AppleShowAllFiles = true;
    };

    "com.apple.desktopservices" = {
      # Avoid creating .DS_Store files on network or USB volumes
      DSDontWriteNetworkStores = true;
      DSDontWriteUSBStores = true;
    };

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

    "com.apple.controlcenter" = {
      # Show battery percentage in menu bar.
      BatteryShowPercentage = true;
    };

    "com.apple.menuextra.clock" = {
      # Show 24-hour clock in menu bar.
      Show24Hour = true;
    };

    "com.apple.Safari" = {
      AutoFillPasswords = false; # Use 1Password for passwords.
      IncludeDevelopMenu = true;
    };
  };
}
