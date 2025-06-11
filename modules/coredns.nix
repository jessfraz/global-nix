{
  config,
  lib,
  pkgs,
  ...
}: let
  isDarwin = pkgs.stdenv.isDarwin;

  cfg = config.services.coredns;

  corefilePath =
    if isDarwin
    then pkgs.writeText "Corefile" cfg.config
    else null;
in {
  /*
  imports =
  lib.optional (!isDarwin)
  # Path inside nixpkgs to the upstream module.
  (pkgs.path + "/nixos/modules/services/networking/coredns.nix");
  */

  options = lib.mkIf isDarwin {
    services.coredns = {
      enable = lib.mkEnableOption "CoreDNS DNS server";

      config = lib.mkOption {
        type = lib.types.lines;
        default = "";
        example = ''
          . {
            whoami
          }
        '';
        description = ''
          Verbatim Corefile. See <https://coredns.io/manual/toc/#configuration>.
        '';
      };

      package = lib.mkPackageOption pkgs "coredns" {};

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["-dns.port=1053"];
        description = "Extra CLI flags for CoreDNS.";
      };
    };
  };

  config = lib.mkIf (isDarwin && cfg.enable) {
    # Ship the Corefile.
    environment.etc."coredns/Corefile".source = corefilePath;

    launchd.daemons.coredns = {
      serviceConfig = {
        ProgramArguments =
          [
            "${lib.getBin cfg.package}/bin/coredns"
            "-conf"
            "/etc/coredns/Corefile"
          ]
          ++ cfg.extraArgs;

        # Runs as root by default so it can bind :53; override with
        # `launchd.daemons.coredns.serviceConfig.UserName = "something"`
        # if you’re redirecting port 53 → 1053 via PF.
        KeepAlive = true;
        RunAtLoad = true;
        StandardOutPath = "/var/log/coredns.log";
        StandardErrorPath = "/var/log/coredns.err";
      };

      managedBy = "services.coredns.enable";
    };
  };
}
