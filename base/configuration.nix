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
  programs.bash.enable = true;
  users.users.jessfraz = {
    description = "Jessie Frazelle";
    shell = pkgs.bash;
    home = homeDir;
  };

  environment = {
    systemPackages = [inputs.self.packages.${pkgs.system}.default];
  };

  nix = {
    enable = true;
    gc = {
      automatic = true;
      interval = {
        Day = 5;
      };
      options = "--delete-older-than 1w";
    };
    optimise = {
      automatic = true;
    };
    settings = {
      experimental-features = ["nix-command" "flakes"];
      trusted-users = ["jessfraz"];
    };
    package = pkgs.nixVersions.stable;
  };
}
