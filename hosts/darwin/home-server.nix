{...}: {
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
}
