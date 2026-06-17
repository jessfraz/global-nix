{
  config,
  lib,
  pkgs,
  ...
}: let
  defaultUser =
    if pkgs.stdenv.isDarwin
    then (config.users.primaryUser or (builtins.getEnv "USER"))
    else "scrypted";
  storagePath = config.services.scrypted.storagePath;
  npmCacheDir = "${storagePath}/npm-cache";
  launchdResilience = {
    KeepAlive = true;
    RunAtLoad = true;
    ThrottleInterval = 30;
    ExitTimeOut = 30;
    ProcessType = "Background";
  };
in {
  options = {
    services.scrypted = {
      enable = lib.mkEnableOption "Scrypted Smart-Home bridge";

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.scrypted;
        description = "Scrypted server package to run.";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default =
          defaultUser;
        description = "Account Scrypted should run under (root not recommended).";
      };

      storagePath = lib.mkOption {
        type = lib.types.path;
        default =
          if pkgs.stdenv.isDarwin
          then "/Users/${config.services.scrypted.user}/.scrypted"
          else "/var/lib/scrypted";
        description = "Where Scrypted stores its database and plugins.";
      };

      nodePackage = lib.mkOption {
        type = lib.types.package;
        default = pkgs.nodejs_22; # matches the installer’s 22.14.0
        description = "Node runtime used to run Scrypted.";
      };

      pythonPackage = lib.mkOption {
        type = lib.types.package;
        default = pkgs.python311;
        description = "Python runtime exposed to Scrypted plugins.";
      };

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Additional arguments appended to the Scrypted server launcher.";
      };
    };
  };

  config = lib.mkIf config.services.scrypted.enable (lib.mkMerge [
    {
      environment.systemPackages = [
        config.services.scrypted.nodePackage
        config.services.scrypted.pythonPackage
        config.services.scrypted.package
        pkgs.ffmpeg
        pkgs.gst_all_1.gstreamer
      ];
    }

    (lib.mkIf (pkgs.stdenv.isLinux && config.services.scrypted.user != "root") {
      users.groups.${config.services.scrypted.user} = {};
      users.users.${config.services.scrypted.user} = {
        isSystemUser = true;
        group = config.services.scrypted.user;
        home = config.services.scrypted.storagePath;
        createHome = true;
      };
    })

    (lib.mkIf pkgs.stdenv.isDarwin {
      system.activationScripts.scrypted-mkdir.text = ''
        install -d -m0755 -o ${config.services.scrypted.user} -g staff ${storagePath}
        install -d -m0755 -o ${config.services.scrypted.user} -g staff ${storagePath}/volume
        install -d -m0755 -o ${config.services.scrypted.user} -g staff ${npmCacheDir}

        legacy_agent="/Users/${config.services.scrypted.user}/Library/LaunchAgents/app.scrypted.server.plist"
        if [ -e "$legacy_agent" ]; then
          uid="$(/usr/bin/id -u ${lib.escapeShellArg config.services.scrypted.user} 2>/dev/null || true)"
          if [ -n "$uid" ]; then
            /bin/launchctl bootout "gui/$uid" "$legacy_agent" 2>/dev/null || true
          fi
          rm -f "$legacy_agent"
        fi
      '';

      launchd.user.agents.scrypted = {
        serviceConfig =
          {
            ProgramArguments =
              [
                "${config.services.scrypted.package}/bin/scrypted-serve"
              ]
              ++ config.services.scrypted.extraArgs;

            EnvironmentVariables = {
              NODE_OPTIONS = "--dns-result-order=ipv4first";
              # prepend the nix bins *then* the standard macOS dirs
              PATH = lib.concatStringsSep ":" ([
                  "${config.services.scrypted.pythonPackage}/bin"
                  "${config.services.scrypted.nodePackage}/bin"
                  "${pkgs.ffmpeg}/bin"
                  "${pkgs.gst_all_1.gstreamer}/bin"
                ]
                ++ [
                  "/usr/local/bin" # keep Homebrew happy if you use it
                  "/usr/bin"
                  "/bin"
                  "/usr/sbin"
                  "/sbin"
                ]);

              SCRYPTED_PYTHON_PATH = "python${config.services.scrypted.pythonPackage.pythonVersion or "3.11"}";
              SCRYPTED_FFMPEG_PATH = "${pkgs.ffmpeg}/bin/ffmpeg";
              SCRYPTED_INSTALL_PATH = storagePath;
              SCRYPTED_VOLUME = "${storagePath}/volume";
              NPM_CONFIG_CACHE = npmCacheDir;
              NPM_CONFIG_UPDATE_NOTIFIER = "false";
              NPM_CONFIG_AUDIT = "false";
              NPM_CONFIG_FUND = "false";

              HOME = storagePath;
            };

            StandardOutPath = "${storagePath}/scrypted.log";
            StandardErrorPath = "${storagePath}/scrypted.log";

            WorkingDirectory = storagePath;
          }
          // launchdResilience;
      };
    })

    /*
      (lib.mkIf pkgs.stdenv.isLinux {
      systemd.tmpfiles.rules = [
        "d ${config.services.scrypted.storagePath} 0755 ${config.services.scrypted.user} ${config.services.scrypted.user} - -"
      ];

      systemd.user.services.scrypted = {
        Unit = {
          Description = "Scrypted Smart-Home bridge";
          After = ["network-online.target"];
        };
        Service = {
          ExecStart = lib.concatStringsSep " " (
            ["${config.services.scrypted.package}/bin/scrypted-serve"]
            ++ config.services.scrypted.extraArgs
          );
          WorkingDirectory = config.services.scrypted.storagePath;
          Environment = {
            NODE_OPTIONS = "--dns-result-order=ipv4first";
            PATH = lib.concatStringsSep ":" [
              "${config.services.scrypted.pythonPackage}/bin"
              "${config.services.scrypted.nodePackage}/bin"
              "${pkgs.ffmpeg}/bin"
              "$PATH"
            ];
            SCRYPTED_PYTHON_PATH = "python${config.services.scrypted.pythonPackage.pythonVersion or "3.11"}";
            SCRYPTED_FFMPEG_PATH = "${pkgs.ffmpeg}/bin/ffmpeg";
            SCRYPTED_INSTALL_PATH = config.services.scrypted.storagePath;
          };
          Restart = "on-failure";
        };
        Install = {WantedBy = ["default.target"];};
      };
    })
    */
  ]);
}
