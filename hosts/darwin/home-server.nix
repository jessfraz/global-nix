{...}: {
  imports = [
    ./tailscale-home-server.nix
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
