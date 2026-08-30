{...}: let
  # Home Assistant Green's UniFi-reserved IPv4 address.
  homeAssistantGreenAddress = "192.168.1.80";
  homeAssistantPort = 8123;
in {
  imports = [
    (import ./tailscale-home-server.nix {
      inherit homeAssistantGreenAddress homeAssistantPort;
    })
    ./coredns.nix
    ./containers/certbot-renew.nix
    ./containers/nginx.nix
    ./containers/tripitcalb0t.nix
    ./containers/znc.nix
  ];

  globalNix.determinateNix.extraConfig = ''
    max-jobs = 1
    cores = 2
  '';

  homebrew = {
    enable = true;

    brews = [
      "docker"
    ];

    casks = [
      "docker"
      "ghostty"
    ];
  };
}
