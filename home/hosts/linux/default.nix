{
  pkgs,
  inputs,
  config,
  lib,
  ...
}: {
  imports = [
    inputs.rex.homeManagerModules.default
  ];

  services.rex.enable = true;

  home.activation.rexAgents = lib.hm.dag.entryAfter ["linkGeneration"] ''
    $DRY_RUN_CMD ${config.programs.rex.package}/bin/rex --autostart=false skill setup
  '';

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
