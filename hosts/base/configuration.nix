{
  config,
  pkgs,
  inputs,
  ...
}: let
  homeDir =
    if pkgs.stdenv.isLinux
    then "/home/jessfraz"
    else "/Users/jessfraz";
in {
  users.users.jessfraz = {
    description = "Jessie Frazelle";
    shell = pkgs.bash;
    home = homeDir;
  };

  nix = {
    enable = true;
    optimise = {
      automatic = true;
    };
    settings = {
      experimental-features = ["nix-command" "flakes"];
      trusted-users = ["jessfraz"];
    };
    package = pkgs.nixVersions.stable;
  };

  environment = {
    systemPackages = [inputs.self.packages.${pkgs.system}.default];
  };

  fonts.packages = with pkgs; [
    nerd-fonts.hack
  ];
}
