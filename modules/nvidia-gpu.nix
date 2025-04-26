{
  nixpkgs.allowUnfreePackages = [
    "nvidia-x11"
    "nvidia-settings"
  ];
  flake.modules.nixos.nvidia-gpu =
    { pkgs, ... }:
    {
      nixpkgs.config.nvidia.acceptLicense = true;
      boot.initrd.kernelModules = [ "nvidia" ];

      # Load nvidia driver for Xorg and Wayland
      services.xserver.videoDrivers = [ "nvidia" ];

      hardware = {
        graphics.extraPackages = [ pkgs.nvidia-vaapi-driver ];
        nvidia-container-toolkit.enable = false;

        # Enable the Nvidia settings menu,
        # accessible via `nvidia-settings`.
        #nvidia.nvidiaSettings = true;
      };

    };
}
