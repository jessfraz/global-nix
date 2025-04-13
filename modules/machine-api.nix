{
  flake.modules.nixos.desktop.networking = {
    firewall = {
      allowedTCPPorts = [
        8585 # running machine-api locally
      ];
      allowedUDPPorts = [
        5353 # mDNS allow for machine-api
      ];
    };
  };
}
