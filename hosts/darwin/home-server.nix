{
  username,
  volumesPath,
  ...
}: let
  # Set this to Home Assistant Green's UniFi-reserved IPv4 address once the
  # appliance is installed. Until then, the old loopback proxy is withdrawn.
  homeAssistantGreenAddress = null;
  homeAssistantPort = 8123;
  servicePorts = {
    scrypted = 10443;
  };
in {
  imports = [
    (import ./tailscale-home-server.nix {
      inherit homeAssistantGreenAddress homeAssistantPort servicePorts;
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

  services.scrypted = {
    enable = true;

    user = username;
    #storagePath = "${volumesPath}/scrypted";
  };

  services.darwinServiceWatchdog = {
    enable = true;
    user = username;
    restartMaxLoadAverage = 32;
    restartMaxSwapUsedMiB = 4096;

    checks = {
      scrypted = {
        label = "org.nixos.scrypted";
        urls = ["https://127.0.0.1:${toString servicePorts.scrypted}"];
        startupGraceSeconds = 600;
        failureThreshold = 3;
        restartCooldownSeconds = 900;
        logFiles = [
          {
            path = "/Users/${username}/.scrypted/scrypted.log";
            maxBytes = 104857600;
            keepBytes = 20971520;
          }
        ];
      };
    };
  };
}
