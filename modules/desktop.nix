{
  flake.modules.nixos.desktop = {
    hardware.graphics = {
      enable = true;
      enable32Bit = true;
    };
    environment.systemPackages = [
      #pkgs.egl-wayland
    ];
  };

}
