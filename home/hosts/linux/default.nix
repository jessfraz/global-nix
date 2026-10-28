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

  systemd.user.services.agent = {
    Unit = {
      Description = "Agent worker";
      After = ["rex.service"];
      Wants = ["rex.service"];
    };
    Service = {
      ExecStart = "${inputs.agent.packages.${pkgs.stdenv.hostPlatform.system}.default}/bin/agent --config ${config.xdg.configHome}/agent/config.toml maintain";
      WorkingDirectory = config.home.homeDirectory;
      # Workers need the same provider and credential tools as interactive shells.
      Environment = ["PATH=${config.home.profileDirectory}/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin"];
      Restart = "on-failure";
      RestartSec = 10;
      # The worker handles SIGINT to stop its registration and background tasks.
      KillSignal = "SIGINT";
      UMask = "0077";
    };
    Install.WantedBy = ["default.target"];
  };

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
