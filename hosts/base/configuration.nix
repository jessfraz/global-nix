{
  pkgs,
  inputs,
  homeDir,
  username,
  ...
}: {
  users.users.${username} = {
    description = "Jessie Frazelle";
    shell = pkgs.bash;
    home = homeDir;
  };

  nix = {
    settings = {
      experimental-features = ["nix-command" "flakes"];
      trusted-users = [username];
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
