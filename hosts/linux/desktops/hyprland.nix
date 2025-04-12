{
  config,
  pkgs,
  ...
}: {
  programs = {
    hyprland = {
      enable = true;

      # Whether to enable XWayland, so xapps still work.
      xwayland = {
        enable = true;
      };
    };
  };

  environment = {
    sessionVariables = {
      # Enable Ozone Wayland support in Chromium and Electron apps.
      NIXOS_OZONE_WL = "1";
      EGL_PLATFORM = "wayland";
    };

    systemPackages = [
      pkgs.kitty # required for the default Hyprland config
    ];
  };
}
