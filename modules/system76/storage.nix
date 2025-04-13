{
  flake.modules.nixos."nixosConfigurations/system76" = {
    fileSystems = {
      "/" = {
        device = "/dev/disk/by-uuid/3807d0c9-acdb-4778-a011-6f20cd766643";
        fsType = "ext4";
      };

      "/boot" = {
        device = "/dev/disk/by-uuid/6B13-6807";
        fsType = "vfat";
        options = [
          "fmask=0077"
          "dmask=0077"
        ];
      };
    };

    boot.initrd.luks.devices."luks-141c4d58-4b26-40d1-b9d9-04b1bf42c32a".device =
      "/dev/disk/by-uuid/141c4d58-4b26-40d1-b9d9-04b1bf42c32a";
  };
}
