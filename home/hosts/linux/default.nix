{pkgs, ...}: {
  imports = [
  ];

  home.packages = with pkgs; [
    #egl-wayland
  ];

  home.pointerCursor = {
    enable = true;
    package = pkgs.vanilla-dmz;
    name = "Vanilla-DMZ";
    gtk.enable = true;
  };
}
