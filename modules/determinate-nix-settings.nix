{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.globalNix.determinateNix;
  customConfig = pkgs.writeText "nix.custom.conf" cfg.extraConfig;
in {
  options.globalNix.determinateNix.extraConfig = lib.mkOption {
    type = lib.types.lines;
    default = "";
    internal = true;
    description = "Settings written to Determinate Nix's nix.custom.conf include.";
  };

  config = {
    globalNix.determinateNix.extraConfig =
      lib.mkBefore (builtins.readFile ../hosts/darwin/nix.custom.conf);

    system.activationScripts.extraActivation.text = lib.mkAfter ''
      if ! /usr/bin/cmp -s ${customConfig} /etc/nix/nix.custom.conf; then
        install -d -m0755 /etc/nix
        install -m0644 ${customConfig} /etc/nix/nix.custom.conf
        /bin/launchctl kickstart -k system/systems.determinate.nix-daemon
      fi
    '';
  };
}
