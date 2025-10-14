{
  config,
  lib,
  pkgs,
  ...
}: let
  defaultUser =
    if pkgs.stdenv.isDarwin
    then (config.users.primaryUser or (builtins.getEnv "USER"))
    else "homebridge";
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
          else defaultUser;
        description = "Account the service runs under.";
      };

      storagePath = lib.mkOption {
        type = lib.types.path;
        default =
          if pkgs.stdenv.isDarwin
          then "/Users/${config.services.homebridge.user}/.homebridge"
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

  config = lib.mkIf config.services.homebridge.enable (lib.mkMerge [
    {
      environment.systemPackages = [
        config.services.homebridge.package
        pkgs.nodejs_20
      ];
    }

    (lib.mkIf pkgs.stdenv.isDarwin (let
      defaultPath =
        lib.concatStringsSep ":"
        ([
            (lib.makeBinPath [pkgs.nodejs_20 config.services.homebridge.package])
          ]
          ++ [
            "/usr/local/bin"
            "/usr/bin"
            "/bin"
            "/usr/sbin"
            "/sbin"
          ]);
    in {
      system.activationScripts.homebridge-mkdir = ''
        install -d -m0755 -o ${config.services.homebridge.user} -g staff ${config.services.homebridge.storagePath}
      '';

      launchd.user.agents.homebridge = {
        serviceConfig = {
          ProgramArguments =
            [
              "${config.services.homebridge.package}/bin/homebridge"
              "-U"
              config.services.homebridge.storagePath
              "-I"
              "-P"
              "${config.services.homebridge.storagePath}/node_modules"
              "--color"
            ]
            ++ config.services.homebridge.extraArgs;

          EnvironmentVariables =
            ({
                HOMEBRIDGE_LOG_PATH = "${config.services.homebridge.storagePath}/homebridge.*";
              }
              // lib.optionalAttrs (!(config.services.homebridge.environment ? PATH)) {
                PATH = defaultPath;
              })
            // config.services.homebridge.environment;

          StandardOutPath = "${config.services.homebridge.storagePath}/homebridge.log";
          StandardErrorPath = "${config.services.homebridge.storagePath}/homebridge.log";

          KeepAlive = true;
          RunAtLoad = true;
        };

        managedBy = "services.homebridge.enable";
      };
    }))

    /*
      (lib.mkIf pkgs.stdenv.isLinux {
      users.groups.${config.services.homebridge.user} = {};
      users.users.${config.services.homebridge.user} = {
        isSystemUser = true;
        group = config.services.homebridge.user;
        home = config.services.homebridge.storagePath;
        createHome = true;
      };

      systemd.tmpfiles.rules = [
        "d ${config.services.homebridge.storagePath} 0755 ${config.services.homebridge.user} ${config.services.homebridge.user} - -"
      ];

      systemd.services.homebridge = {
        description = "Homebridge (HomeKit bridge)";
        after = ["network-online.target"];
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          User = config.services.homebridge.user;
          Group = config.services.homebridge.user;
          WorkingDirectory = config.services.homebridge.storagePath;
          ExecStart =
            "${config.services.homebridge.package}/bin/homebridge -U ${config.services.homebridge.storagePath} -I "
            + lib.concatStringsSep " " config.services.homebridge.extraArgs;
          Restart = "on-failure";
          Environment =
            lib.concatStringsSep " " (lib.mapAttrsToList (n: v: "${n}=${v}") config.services.homebridge.environment);
        };
      };
    })
    */
  ]);
}
