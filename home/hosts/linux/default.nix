{pkgs, ...}: {
  imports = [
    ./desktops/hyprland.nix
  ];

  home.packages = with pkgs; [
    egl-wayland
  ];
}
