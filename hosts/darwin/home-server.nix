{...}: {
  services.agent.role = "coordinator";

  imports = [
    ./tailscale-home-server.nix
    ./coredns.nix
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
    ];
  };
}
