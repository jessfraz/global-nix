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
  };
}
