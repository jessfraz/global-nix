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
    # Enable Ozone Wayland support in Chromium and Electron apps.
    sessionVariables.NIXOS_OZONE_WL = "1";
    systemPackages = [
      pkgs.kitty # required for the default Hyprland config
    ];
  };
}
