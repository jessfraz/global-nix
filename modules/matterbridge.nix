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
  # Keep npm writes out of /nix/store and stable across upgrades.
  npmGlobalDir = "${dataDir}/npm-global";
  npmCacheDir = "${dataDir}/npm-cache";
  logPath = "${dataDir}/matterbridge.log";
  # Wrapper ensures Matterbridge plugins can install and resolve dependencies.
  launchScript = pkgs.writeShellScript "matterbridge-launch" ''
    set -euo pipefail

    mkdir -p "${npmGlobalDir}" "${npmCacheDir}"

    if [ ! -d "${npmGlobalDir}/lib/node_modules/matterbridge" ]; then
      HOME=${baseDir} \
      NPM_CONFIG_PREFIX=${npmGlobalDir} \
      NPM_CONFIG_CACHE=${npmCacheDir} \
      "${config.services.matterbridge.nodePackage}/bin/npm" \
        install -g matterbridge --omit=dev --prefix "${npmGlobalDir}" --cache "${npmCacheDir}"
    fi

    mkdir -p "${npmGlobalDir}/lib/node_modules/node_modules"
    # ESM resolution looks for node_modules in ancestor dirs, so provide one.
    if [ ! -e "${npmGlobalDir}/lib/node_modules/node_modules/matterbridge" ]; then
      ln -s "../matterbridge" "${npmGlobalDir}/lib/node_modules/node_modules/matterbridge"
    fi

    # Matterbridge moved frontend assets from frontend/ to apps/frontend/.
    # Keep a compatibility link so old/new layouts both resolve.
    if [ -d "${npmGlobalDir}/lib/node_modules/matterbridge/apps/frontend" ] && [ ! -e "${npmGlobalDir}/lib/node_modules/matterbridge/frontend" ]; then
      ln -s "apps/frontend" "${npmGlobalDir}/lib/node_modules/matterbridge/frontend"
    fi
    if [ -d "${npmGlobalDir}/lib/node_modules/matterbridge/frontend" ] && [ ! -e "${npmGlobalDir}/lib/node_modules/matterbridge/apps/frontend" ]; then
      mkdir -p "${npmGlobalDir}/lib/node_modules/matterbridge/apps"
      ln -s "../frontend" "${npmGlobalDir}/lib/node_modules/matterbridge/apps/frontend"
    fi

    exec "${npmGlobalDir}/bin/matterbridge" --nosudo "$@"
  '';
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
        install -d -m0755 -o ${config.services.matterbridge.user} -g staff ${npmCacheDir}
      '';

      launchd.user.agents.matterbridge = {
        serviceConfig = {
          ProgramArguments =
            [
              "${launchScript}"
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
            NPM_CONFIG_CACHE = npmCacheDir;
            NODE_PATH = "${npmGlobalDir}/lib/node_modules";
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
