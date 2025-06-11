{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.homebridge;
in {
  options = {
    services.homebridge = {
      enable = lib.mkEnableOption "Homebridge automation bridge";

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.homebridge;
        description = "Homebridge package to run.";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default =
          if pkgs.stdenv.isDarwin
          then config.users.primaryUser or "${builtins.getEnv "USER"}"
          else "homebridge";
        description = "Account the service runs under.";
      };

      storagePath = lib.mkOption {
        type = lib.types.path;
        default =
          if pkgs.stdenv.isDarwin
          then "/Users/${cfg.user}/.homebridge"
          else "/var/lib/homebridge";
        description = "Config/cache directory.";
      };

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Extra CLI flags.";
      };

      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = "Additional env vars.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      environment.systemPackages = [
        cfg.package
        pkgs.nodejs_20
      ];
    }

    (lib.mkIf (builtins.hasAttr "launchd" lib.options) {
      system.activationScripts.homebridge-mkdir = ''
        install -d -m0755 -o ${cfg.user} -g staff ${cfg.storagePath}
      '';

      launchd.agents.homebridge = {
        enable = true;
        serviceConfig = {
          ProgramArguments =
            [
              "${cfg.package}/bin/homebridge"
              "-U"
              cfg.storagePath
              "-I"
            ]
            ++ cfg.extraArgs;
          WorkingDirectory = cfg.storagePath;
          UserName = cfg.user;
          KeepAlive = true;
          RunAtLoad = true;
          StandardOutPath = "${cfg.storagePath}/homebridge.log";
          StandardErrorPath = "${cfg.storagePath}/homebridge.err";
          EnvironmentVariables = cfg.environment;
        };
      };
    })

    /*
      (lib.mkIf (builtins.hasAttr "systemd" lib.options) {
      users.groups.${cfg.user} = {};
      users.users.${cfg.user} = {
        isSystemUser = true;
        group = cfg.user;
        home = cfg.storagePath;
        createHome = true;
      };

      systemd.tmpfiles.rules = [
        "d ${cfg.storagePath} 0755 ${cfg.user} ${cfg.user} - -"
      ];

      systemd.services.homebridge = {
        description = "Homebridge (HomeKit bridge)";
        after = ["network-online.target"];
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          User = cfg.user;
          Group = cfg.user;
          WorkingDirectory = cfg.storagePath;
          ExecStart =
            "${cfg.package}/bin/homebridge -U ${cfg.storagePath} -I "
            + lib.concatStringsSep " " cfg.extraArgs;
          Restart = "on-failure";
          Environment =
            lib.concatStringsSep " " (lib.mapAttrsToList (n: v: "${n}=${v}") cfg.environment);
        };
      };
    })
    */
  ]);
}
