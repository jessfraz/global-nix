{pkgs, ...}: {
  imports = [
  ];

  home.packages = with pkgs; [
    #egl-wayland
  ];

  home.pointerCursor = {
    package = pkgs.vanilla-dmz;
    name = "Vanilla-DMZ";
    gtk.enable = true;
  };
}
