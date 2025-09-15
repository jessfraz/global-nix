{
  username,
  hostname,
  ...
}: {
  # Let Determinate Nix handle Nix configuration
  nix.enable = false;

  networking = {
    hostName = hostname;
    computerName = hostname;
  };

  # Add ability to used TouchID for sudo authentication.
  security = {
    pam = {
      services = {
        sudo_local = {
          enable = true;
          touchIdAuth = true;
        };
      };
    };
  };

  # MacOS system preferences.
  system.primaryUser = username;
  system.defaults = {
    NSGlobalDomain = {
      # Whether to always show hidden files.
      AppleShowAllFiles = true;
      # Whether to automatically switch between light and dark mode.
      AppleInterfaceStyleSwitchesAutomatically = true;
      # Show all the file extensions.
      AppleShowAllExtensions = true;
    };

    SoftwareUpdate = {
      AutomaticallyInstallMacOSUpdates = true;
    };

    menuExtraClock = {
      Show24Hour = true;
    };

    controlcenter = {
      # Show battery percentage in menu bar.
      BatteryShowPercentage = true;
    };

    dock = {
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

    finder = {
      # Whether to always show hidden files.
      AppleShowAllFiles = true;
      # Show status bar at bottom of finder windows with item/disk space stats.
      ShowStatusBar = true;
      # Show path breadcrumbs in finder windows.
      ShowPathbar = true;
      # Remove items in the trash after 30 days.
      FXRemoveOldTrashItems = true;
      # Whether to always show file extensions.
      AppleShowAllExtensions = true; # show all file extensions
      # Whether to show external disks on desktop.
      ShowExternalHardDrivesOnDesktop = true;
      # Whether to show removable media (CDs, DVDs and iPods) on desktop.
      ShowRemovableMediaOnDesktop = true;
      # Whether to show connected servers on desktop.
      ShowMountedServersOnDesktop = true;

      # Whether to show the full POSIX filepath in the window title.
      _FXShowPosixPathInTitle = true;

      # Whether to show warnings when change the file extension of files.
      FXEnableExtensionChangeWarning = true;
    };

    loginwindow = {
      # Disable the guest user account.
      GuestEnabled = false;
    };

    smb = {
      NetBIOSName = hostname;
      ServerDescription = hostname;
    };

    CustomSystemPreferences = {
      "com.apple.AdLib" = {
        allowApplePersonalizedAdvertising = false;
        allowIdentifierForAdvertising = false;
        forceLimitAdTracking = true;
        personalizedAdsMigrated = false;
      };
    };
  };

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 6;
}
