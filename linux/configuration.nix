{
  config,
  pkgs,
  ...
}: {
  imports = [];

  nix.settings.experimental-features = ["nix-command" "flakes"];

  users.users.jessfraz = {
    isNormalUser = true;
    description = "Jessie Frazelle";
  };

  environment.systemPackages = [pkgs.git];
}
