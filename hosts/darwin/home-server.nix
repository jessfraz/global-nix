{
  username,
  volumesPath,
  ...
}: {
  imports = [
    ./coredns.nix
    ./containers/certbot-renew.nix
    ./containers/nginx.nix
    ./containers/tripitcalb0t.nix
    ./containers/znc.nix
  ];

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

  services.homebridge = {
    enable = true;

    user = username;
    #storagePath = "${volumesPath}/homebridge";
    ui.enable = true;
  };

  services.matterbridge = {
    enable = true;

    user = username;
    #storagePath = "${volumesPath}/matterbridge";
  };

  services.darwinServiceWatchdog = {
    enable = true;
    user = username;

    checks = {
      homebridge = {
        label = "org.nixos.homebridge";
        urls = ["http://127.0.0.1:8581"];
        startupGraceSeconds = 300;
        failureThreshold = 3;
        restartCooldownSeconds = 600;
        logFiles = [
          {
            path = "/Users/${username}/.homebridge/homebridge.log";
            maxBytes = 10485760;
            keepBytes = 1048576;
          }
        ];
      };

      scrypted = {
        label = "org.nixos.scrypted";
        urls = ["https://127.0.0.1:10443"];
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

      matterbridge = {
        label = "org.nixos.matterbridge";
        urls = ["http://127.0.0.1:8283"];
        startupGraceSeconds = 300;
        failureThreshold = 3;
        restartCooldownSeconds = 600;
        logFiles = [
          {
            path = "/Users/${username}/.matterbridge/matterbridge.log";
            maxBytes = 10485760;
            keepBytes = 1048576;
          }
        ];
      };
    };
  };
}
