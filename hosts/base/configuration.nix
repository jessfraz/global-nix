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
    enable = true;
    optimise = {
      automatic = true;
    };
    settings = {
      experimental-features = ["nix-command" "flakes"];
      trusted-users = [username];
      # Use additional binary caches to reduce local builds.
      # FlakeHub Cache (Determinate Systems) and nix-community Cachix.
      substituters = [
        "https://cache.nixos.org"
        "https://cache.flakehub.com"
        "https://nix-community.cachix.org"
      ];
      trusted-public-keys = [
        # cache.nixos.org default key
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        # FlakeHub Cache public keys
        "cache.flakehub.com-3:hJuILl5sVK4iKm86JzgdXW12Y2Hwd5G07qKtHTOcDCM="
        "cache.flakehub.com-4:Asi8qIv291s0aYLyH6IOnr5Kf6+OF14WVjkE6t3xMio="
        "cache.flakehub.com-5:zB96CRlL7tiPtzA9/WKyPkp3A2vqxqgdgyTVNGShPDU="
        "cache.flakehub.com-6:W4EGFwAGgBj3he7c5fNh9NkOXw0PUVaxygCVKeuvaqU="
        "cache.flakehub.com-7:mvxJ2DZVHn/kRxlIaxYNMuDG1OvMckZu32um1TadOR8="
        "cache.flakehub.com-8:moO+OVS0mnTjBTcOUh2kYLQEd59ExzyoW1QgQ8XAARQ="
        "cache.flakehub.com-9:wChaSeTI6TeCuV/Sg2513ZIM9i0qJaYsF+lZCXg0J6o="
        "cache.flakehub.com-10:2GqeNlIp6AKp4EF2MVbE1kBOp9iBSyo0UPR9KoR0o1Y="
        # nix-community public cache key
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];
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
