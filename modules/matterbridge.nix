{
  config,
  lib,
  pkgs,
  ...
}: let
  defaultUser =
    if pkgs.stdenv.isDarwin
    then (config.users.primaryUser or (builtins.getEnv "USER"))
    else "matterbridge";
  baseDir = config.services.matterbridge.storagePath;
  pluginDir = "${baseDir}/Matterbridge";
  dataDir = "${baseDir}/.matterbridge";
  certDir = "${baseDir}/.mattercert";
  npmGlobalDir = "${dataDir}/npm-global";
  logPath = "${dataDir}/matterbridge.log";
in {
  options = {
    services.matterbridge = {
      enable = lib.mkEnableOption "Matterbridge plugin manager for Matter";

      user = lib.mkOption {
        type = lib.types.str;
        default = defaultUser;
        description = "Account Matterbridge should run under.";
      };

      storagePath = lib.mkOption {
        type = lib.types.path;
        default =
          if pkgs.stdenv.isDarwin
          then "/Users/${config.services.matterbridge.user}"
          else "/var/lib/matterbridge";
        description = "Base directory that holds Matterbridge data and plugins.";
      };

      nodePackage = lib.mkOption {
        type = lib.types.package;
        default = pkgs.nodejs_22;
        description = "Node runtime used to run Matterbridge.";
      };

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Extra CLI flags passed to Matterbridge.";
      };
    };
  };

  config = lib.mkIf config.services.matterbridge.enable (lib.mkMerge [
    {
      environment.systemPackages = [
        config.services.matterbridge.nodePackage
      ];
    }

    (lib.mkIf pkgs.stdenv.isDarwin {
      system.activationScripts.matterbridge-mkdir = ''
        if [ ! -d "${baseDir}" ]; then
          install -d -m0755 -o ${config.services.matterbridge.user} -g staff ${baseDir}
        fi
        install -d -m0755 -o ${config.services.matterbridge.user} -g staff ${pluginDir}
        install -d -m0755 -o ${config.services.matterbridge.user} -g staff ${dataDir}
        install -d -m0755 -o ${config.services.matterbridge.user} -g staff ${certDir}
        install -d -m0755 -o ${config.services.matterbridge.user} -g staff ${npmGlobalDir}
      '';

      launchd.daemons.matterbridge = {
        serviceConfig = {
          UserName = config.services.matterbridge.user;
          ProgramArguments =
            [
              "${config.services.matterbridge.nodePackage}/bin/npx"
              "-y"
              "matterbridge"
              "--nosudo"
            ]
            ++ config.services.matterbridge.extraArgs;

          EnvironmentVariables = {
            PATH = lib.concatStringsSep ":" ([
                "${config.services.matterbridge.nodePackage}/bin"
                "${npmGlobalDir}/bin"
              ]
              ++ [
                "/usr/local/bin"
                "/usr/bin"
                "/bin"
                "/usr/sbin"
                "/sbin"
              ]);
            HOME = baseDir;
            NPM_CONFIG_PREFIX = npmGlobalDir;
          };

          WorkingDirectory = pluginDir;
          StandardOutPath = logPath;
          StandardErrorPath = logPath;

          KeepAlive = {
            PathState = {
              "/nix/store" = true;
            };
          };
          RunAtLoad = true;
        };
      };
    })
  ]);
}
