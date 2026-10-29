{
  username,
  hostname,
  homeDir,
  inputs,
  config,
  pkgs,
  lib,
  ...
}: let
  maxFilesSoft = 65536;
  maxFilesHard = 200000;
  launchctlPath = "/bin/launchctl";
in {
  imports = [
    ../../modules/determinate-nix-settings.nix
    inputs.agent.darwinModules.default
  ];

  services.agent = {
    enable = true;
    configFile = "${homeDir}/.config/agent/config.toml";
    workingDirectory = homeDir;
    extraPackages =
      [
        inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.gws
        inputs.switchboard.packages.${pkgs.stdenv.hostPlatform.system}.switchboard
        inputs.switchboard.packages.${pkgs.stdenv.hostPlatform.system}.messages
        pkgs.gh
        pkgs.uv
        pkgs.ripgrep
        pkgs.tailscale
      ]
      ++ builtins.filter
      (package: builtins.elem (lib.getName package) ["rex" "with-credentials"])
      config.home-manager.users.${username}.home.packages;
  };

  home-manager.users.${username}.programs.agent = {
    enable = true;
    package = inputs.agent.packages.${pkgs.stdenv.hostPlatform.system}.default;
    role = config.services.agent.role;
  };

  launchd.user.agents.agent.serviceConfig = {
    StandardOutPath = "${homeDir}/Library/Logs/agent.log";
    StandardErrorPath = "${homeDir}/Library/Logs/agent.log";
    Umask = 63;
  };

  # Let Determinate Nix handle Nix configuration
  nix.enable = false;

  launchd = {
    # Raise file descriptor limits for both the system and the user domains.
    daemons."limit.maxfiles" = {
      serviceConfig = {
        ProgramArguments = [launchctlPath "limit" "maxfiles" (toString maxFilesSoft) (toString maxFilesHard)];
        RunAtLoad = true;
        StandardErrorPath = "/var/log/limit.maxfiles.err";
        StandardOutPath = "/var/log/limit.maxfiles.out";
      };
    };

    user.agents."${hostname}.limit.maxfiles" = {
      serviceConfig = {
        ProgramArguments = [launchctlPath "limit" "maxfiles" (toString maxFilesSoft) (toString maxFilesHard)];
        RunAtLoad = true;
        StandardErrorPath = "${homeDir}/Library/Logs/limit.maxfiles.err";
        StandardOutPath = "${homeDir}/Library/Logs/limit.maxfiles.out";
      };
    };
  };

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
  # nix-darwin leaves existing administrator accounts outside users.knownUsers.
  # Manage only the login shell so Rex's server-created terminals use Nix Bash.
  system.activationScripts.postActivation.text = lib.mkAfter ''
    /usr/bin/dscl . -create ${lib.escapeShellArg "/Users/${username}"} UserShell /run/current-system/sw/bin/bash
  '';
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
