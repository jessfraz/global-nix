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

      ui = {
        enable = lib.mkEnableOption "Homebridge UI (service mode)";

        packagePath = lib.mkOption {
          type = lib.types.str;
          default = "${config.services.homebridge.storagePath}/node_modules/homebridge-config-ui-x";
          description = "Path to the homebridge-config-ui-x module directory (contains dist/bin/hb-service.js).";
        };

        pluginPath = lib.mkOption {
          type = lib.types.path;
          default = "${config.services.homebridge.storagePath}/node_modules";
          description = "Where Homebridge plugins are installed.";
        };

        nodePackage = lib.mkOption {
          type = lib.types.package;
          default = pkgs.nodejs_22;
          description = "Node runtime used for hb-service.";
        };

        extraArgs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Extra CLI flags passed to hb-service run.";
        };
      };
    };
  };

  config = lib.mkIf config.services.homebridge.enable (lib.mkMerge [
    {
      environment.systemPackages = [
        config.services.homebridge.package
        config.services.homebridge.ui.nodePackage
      ];
    }

    (lib.mkIf pkgs.stdenv.isDarwin (let
      defaultPath =
        lib.concatStringsSep ":"
        ([
            (lib.makeBinPath [config.services.homebridge.ui.nodePackage config.services.homebridge.package])
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
        install -d -m0755 -o ${config.services.homebridge.user} -g staff ${config.services.homebridge.ui.pluginPath}
        if [ ! -e "${config.services.homebridge.ui.pluginPath}/homebridge" ] && [ ! -L "${config.services.homebridge.ui.pluginPath}/homebridge" ]; then
          ln -s "${config.services.homebridge.package}/lib/node_modules/homebridge" "${config.services.homebridge.ui.pluginPath}/homebridge"
        fi
      '';

      launchd.daemons.homebridge =
        if config.services.homebridge.ui.enable
        then {
          serviceConfig = {
            UserName = config.services.homebridge.user;
            ProgramArguments =
              [
                "${config.services.homebridge.ui.nodePackage}/bin/node"
                "${config.services.homebridge.ui.packagePath}/dist/bin/hb-service.js"
                "run"
                "-U"
                config.services.homebridge.storagePath
                "-P"
                config.services.homebridge.ui.pluginPath
              ]
              ++ config.services.homebridge.ui.extraArgs;

            EnvironmentVariables =
              ({
                  HOMEBRIDGE_LOG_PATH = "${config.services.homebridge.storagePath}/homebridge.*";
                }
                // lib.optionalAttrs (!(config.services.homebridge.environment ? PATH)) {
                  PATH = defaultPath;
                })
              // config.services.homebridge.environment;

            WorkingDirectory = config.services.homebridge.storagePath;
            StandardOutPath = "${config.services.homebridge.storagePath}/homebridge.log";
            StandardErrorPath = "${config.services.homebridge.storagePath}/homebridge.log";

            KeepAlive = {
              PathState = {
                "/nix/store" = true;
              };
              SuccessfulExit = false;
            };
            RunAtLoad = true;
          };
        }
        else {
          serviceConfig = {
            UserName = config.services.homebridge.user;
            ProgramArguments =
              [
                "${config.services.homebridge.package}/bin/homebridge"
                "-U"
                config.services.homebridge.storagePath
                "-I"
                "-P"
                config.services.homebridge.ui.pluginPath
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

            KeepAlive = {
              PathState = {
                "/nix/store" = true;
              };
              SuccessfulExit = false;
            };
            RunAtLoad = true;
          };
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
