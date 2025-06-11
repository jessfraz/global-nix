{
  username,
  volumesPath,
  ...
}: {
  imports = [
    ./containers/certbot-renew.nix
    #./containers/homebridge.nix
    ./containers/nginx.nix
    ./containers/tripitcalb0t.nix
    ./containers/znc.nix
  ];

  homebrew = {
    enable = true;
    casks = [
      "docker"
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
