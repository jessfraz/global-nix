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
      extra-substituters = ["https://jessfraz-global-nix.cachix.org"];
      extra-trusted-public-keys = ["jessfraz-global-nix.cachix.org-1:YfZ5ZSDbd3C0ROthje1wND5ps5XameBUZ2ImUokMNy8="];
      trusted-users = [username];
    };
    package = pkgs.nixVersions.stable;
  };

  environment = {
    systemPackages = [inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.default];
  };

  fonts.packages = with pkgs; [
    nerd-fonts.hack
  ];
}
