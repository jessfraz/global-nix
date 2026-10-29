{lib, ...}: {
  boot.initrd = {
    network.ssh = {
      enable = true;
      port = 2222;
      hostKeys = lib.mkDefault ["/etc/secrets/initrd/ssh_host_ed25519_key"];
      extraConfig = ''
        DisableForwarding yes
        ForceCommand systemctl default
      '';
    };
    systemd.network = {
      enable = true;
      # Local unlocking must still work when the Ethernet cable is unplugged.
      wait-online.enable = false;
      networks."10-wired-unlock" = {
        matchConfig.Name = ["en*" "eth*"];
        networkConfig.DHCP = "yes";
        linkConfig.RequiredForOnline = "no";
      };
    };
  };
}
