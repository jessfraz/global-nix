{
  config,
  pkgs,
  ...
}: {
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
    ../desktop/minimal-gnome.nix
  ];

  boot = {
    kernelPackages = pkgs.linuxPackages;
    initrd.kernelModules = ["nvidia"];
    kernelParams = ["nvidia-drm.fbdev=1"];
    extraModprobeConfig = ''
      options nvidia_uvm uvm_disable_hmm=1
    '';
    #blacklistedKernelModules = ["i915"];
    loader.systemd-boot.enable = true;
  };

  networking = {
    hostName = "system76";
  };

  # Enable graphics
  hardware = {
    system76 = {
      enableAll = true;
    };
    graphics = {
      enable = true;
      enable32Bit = true;
      extraPackages = [
        # pkgs.intel-media-driver
        pkgs.nvidia-vaapi-driver
      ];
    };

    nvidia-container-toolkit = {
      enable = false;
    };

    nvidia = {
      # Modesetting is required.
      modesetting.enable = true;

      # Nvidia power management. Experimental, and can cause sleep/suspend to fail.
      powerManagement.enable = true;

      # Fine-grained power management. Turns off GPU when not in use.
      # Experimental and only works on modern Nvidia GPUs (Turing or newer).
      powerManagement.finegrained = true;

      # open source driver, it doesn't suck?
      open = true;

      # forceFullCompositionPipeline = true;

      # Enable the Nvidia settings menu,
      # accessible via `nvidia-settings`.
      #nvidiaSettings = true;
      package = config.boot.kernelPackages.nvidiaPackages.beta;
      # package = config.boot.kernelPackages.nvidiaPackages.mkDriver {
      #    version = "535.171.04";
      #    sha256_64bit = "sha256-6PFkO0vJXYrNZaRHB4SpfazkZC8UkjZGYSDbKqlCQ3o=";
      #    settingsSha256 = "sha256-/+op7FyDk6JH+Oau3dGtawCUtoDdOnfxEXBgYVfufTA=";
      #    persistencedSha256 = "sha256-P90qWA1yObhQQl3sKTWw+uUq7S9ZZcCzKnx/jHbfclo=";
      # };

      # package = let
      #   rcu_patch = pkgs.fetchpatch {
      #     url = "https://github.com/gentoo/gentoo/raw/c64caf53/x11-drivers/nvidia-drivers/files/nvidia-drivers-470.223.02-gpl-pfn_valid.patch";
      #     hash = "sha256-eZiQQp2S/asE7MfGvfe6dA/kdCvek9SYa/FFGp24dVg=";
      #   };
      # in config.boot.kernelPackages.nvidiaPackages.mkDriver {
      #     version = "550.40.07";
      #     sha256_64bit = "sha256-KYk2xye37v7ZW7h+uNJM/u8fNf7KyGTZjiaU03dJpK0=";
      #     sha256_aarch64 = "sha256-AV7KgRXYaQGBFl7zuRcfnTGr8rS5n13nGUIe3mJTXb4=";
      #     openSha256 = "sha256-mRUTEWVsbjq+psVe+kAT6MjyZuLkG2yRDxCMvDJRL1I=";
      #     settingsSha256 = "sha256-c30AQa4g4a1EHmaEu1yc05oqY01y+IusbBuq+P6rMCs=";
      #     persistencedSha256 = "sha256-11tLSY8uUIl4X/roNnxf5yS2PQvHvoNjnd2CB67e870=";
      #     patches = [ rcu_patch ];
      #  };

      prime = {
        # offload = {
        #  enable = false;
        #  enableOffloadCmd = false;
        # };

        reverseSync = {
          enable = true;
        };
        intelBusId = "PCI:0:2:0";
        nvidiaBusId = "PCI:1:0:0";
      };
    };
  };

  security = {
    rtkit = {
      enable = true;
    };
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.11"; # Did you read the comment?
}
