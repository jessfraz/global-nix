{
  config,
  pkgs,
  inputs,
  ...
}: {
  nix = {
    enable = true;
    gc = {
      automatic = true;
      interval = {
        Day = 5;
      };
      options = "--delete-older-than 1w";
    };
    optimise = {
      automatic = true;
    };
    settings = {
      experimental-features = ["nix-command" "flakes"];
      trusted-users = ["jessfraz"];
    };
    package = pkgs.nixVersions.stable;
  };

  # Add ability to used TouchID for sudo authentication.
  security.pam.services.sudo_local.touchIdAuth = true;

  # MacOS system preferences.
  system.defaults = {
    NSGlobalDomain = {
      # Show all the file extensions.
      AppleShowAllExtensions = true;
    };

    menuExtraClock.Show24Hour = true; # show 24 hour clock

    dock = {
      autohide = true; # Auto-hide the Dock.
      enable-spring-load-actions-on-all-items = true;
      mouse-over-hilite-stack = true;

      mineffect = "genie";
      orientation = "bottom";
      show-recents = false;
      tilesize = 44;
    };

    finder = {
      FXRemoveOldTrashItems = true;
      _FXShowPosixPathInTitle = true; # show full path in finder title
      AppleShowAllExtensions = true; # show all file extensions
      FXEnableExtensionChangeWarning = false; # disable warning when changing file extension
      QuitMenuItem = true; # enable quit menu item
      ShowPathbar = true; # show path bar
      ShowStatusBar = true; # show status bar
    };

    CustomUserPreferences = {
      "com.apple.dock" = {
        magnification = true;
        largesize = 48;
      };

      "com.apple.desktopservices" = {
        # Avoid creating .DS_Store files on network or USB volumes
        DSDontWriteNetworkStores = true;
        DSDontWriteUSBStores = true;
      };

      "com.apple.finder" = {
        AppleShowAllFiles = true;
        ShowExternalHardDrivesOnDesktop = true;
        ShowHardDrivesOnDesktop = false;
        ShowMountedServersOnDesktop = true;
        ShowRemovableMediaOnDesktop = true;
        _FXSortFoldersFirst = true;
        # When performing a search, search the current folder by default
        FXDefaultSearchScope = "SCcf";
      };

      "com.apple.menuextra.battery" = {
        # Battery percentage in menu bar
        ShowPercent = "YES";
      };

      "com.apple.controlcenter" = {
        BatteryShowPercentage = true;
      };

      "com.apple.AdLib" = {
        allowApplePersonalizedAdvertising = false;
      };
    };
  };

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 6;
}
