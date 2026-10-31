{
  pkgs,
  inputs,
  config,
  lib,
  hostname,
  osConfig,
  ...
}: {
  imports = [
    inputs.rex.homeManagerModules.default
  ];

  services.rex = {
    enable = true;
    environment.SHELL = "${config.programs.bash.package}/bin/bash";
    tailscale = {
      enable = true;
      hostname = "${hostname}-rex";
    };
  };

  # Recover the managed unit after a partial Home Manager activation.
  xdg.configFile."systemd/user/agent.service".force = true;

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
      Environment =
        ["PATH=${config.home.profileDirectory}/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin"]
        # User managers can retain a previous login's driver environment.
        ++ lib.optionals (hostname == "system76") [
          "VK_DRIVER_FILES=${osConfig.environment.sessionVariables.VK_DRIVER_FILES}"
        ];
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
