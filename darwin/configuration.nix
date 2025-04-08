{
  config,
  pkgs,
  inputs,
  ...
}: {
  programs.bash.enable = true;
  users.users.jessfraz = {
    description = "Jessie Frazelle";
    shell = pkgs.bash;
    home = "/Users/jessfraz";
  };

  environment = {
    systemPackages = [inputs.self.packages.aarch64-darwin.default];
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

  system.defaults.NSGlobalDomain.AppleShowAllExtensions = true;

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 6;
}
