{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      home-packages-gui = lib.mkMerge [
        (lib.mkOrder 800 [ pkgs.findutils ])
        (lib.mkOrder 1800 [ pkgs.silver-searcher ])
        (lib.mkOrder 2000 [ pkgs.tree ])
      ];
    };

  flake.modules = {
    homeManager = {
      # base =
      #   { pkgs, ... }:
      #   {
      #     home.packages = with pkgs; [
      #       findutils
      #       silver-searcher
      #       tree
      #     ];
      #   };

      gui =
        { lib, pkgs, ... }:
        {
          targets.darwin.defaults = lib.mkIf pkgs.stdenv.isDarwin {
            NSGlobalDomain = {
              # Whether to always show hidden files.
              AppleShowAllFiles = true;
            };
            "com.apple.desktopservices" = {
              # Avoid creating .DS_Store files on network or USB volumes
              DSDontWriteNetworkStores = true;
              DSDontWriteUSBStores = true;
            };
          };
        };

    };

    darwin.gui.system.defaults = {
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

      NSGlobalDomain = {
        # Whether to always show hidden files.
        AppleShowAllFiles = true;
        # Show all the file extensions.
        AppleShowAllExtensions = true;
      };
    };
  };
}
