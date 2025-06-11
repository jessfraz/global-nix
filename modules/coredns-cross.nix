# modules/coredns-cross.nix
{
  config,
  lib,
  pkgs,
  ...
}: let
  # True on macOS, false on everything else.
  isDarwin = pkgs.stdenv.isDarwin;

  # Reuse option names from the upstream NixOS service.
  cfg = config.services.coredns;

  # Only needed on Darwin; on Linux nixpkgs already writes it.
  corefilePath =
    if isDarwin
    then pkgs.writeText "Corefile" cfg.config
    else null;
in {
  ####################################################################
  # 1) Pull in the official NixOS module _only_ when we’re on Linux.
  ####################################################################
  imports =
    lib.optional (!isDarwin)
    # Path inside nixpkgs to the upstream module.
    (pkgs.path + "/nixos/modules/services/networking/coredns.nix");

  ####################################################################
  # 2) Define options only when we’re on Darwin (Linux already has them
  #    from the imported module, so we’d clash if we re-declared them).
  ####################################################################
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

  ####################################################################
  # 3) Darwin-only launchd job (mirrors the upstream systemd unit).
  ####################################################################
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

      # Tie enable/disable directly to the option.
      managedBy = "services.coredns.enable";
    };
  };
}
