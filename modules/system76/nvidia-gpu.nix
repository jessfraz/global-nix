{
  flake.modules.nixos."nixosConfigurations/system76" = nixosArgs: {
    boot = {
      kernelParams = [ "nvidia-drm.fbdev=1" ];

      extraModprobeConfig = ''
        options nvidia_uvm uvm_disable_hmm=1
      '';

      #blacklistedKernelModules = ["i915"];
    };

    environment.sessionVariables = {
      LIBVA_DRIVER_NAME = "nvidia";
      GBM_BACKEND = "nvidia-drm";
      NVD_BACKEND = "direct";
      __GLX_VENDOR_LIBRARY_NAME = "nvidia";
      VK_DRIVER_FILES = "/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.x86_64.json";
    };

    hardware.nvidia = {
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

      package = nixosArgs.config.boot.kernelPackages.nvidiaPackages.beta;
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

        reverseSync.enable = true;
        intelBusId = "PCI:0:2:0";
        nvidiaBusId = "PCI:1:0:0";
      };
    };
  };
}
