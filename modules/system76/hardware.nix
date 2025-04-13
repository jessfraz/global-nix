{
  flake.modules.nixos."nixosConfigurations/system76" = {
    nixpkgs.hostPlatform = "x86_64-linux";

    boot = {
      initrd.availableKernelModules = [
        "xhci_pci"
        "thunderbolt"
        "nvme"
        "sdhci_pci"
      ];

      kernelModules = [ "kvm-intel" ];
    };

    hardware.system76.enableAll = true;
  };
}
