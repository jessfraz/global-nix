{ lib, config, ... }:
let
  nixVersion = "stable";
in
{
  options.nix.settings = lib.mkOption {
    type = lib.types.lazyAttrsOf lib.types.anything;
  };
  config = {
    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
      # SUGGESTION
      #"pipe-operators"
    ];

    flake.modules = {
      nixos.desktop =
        { pkgs, ... }:
        {
          nix = {
            package = pkgs.nixVersions.${nixVersion};
            enable = true;
            optimise.automatic = true;
            settings = config.nix.settings // {
              trusted-users = [ config.flake.meta.owner.username ];
            };

            gc = {
              automatic = true;
              dates = "weekly";
              options = "--delete-older-than 1w";
            };
          };
        };

      darwin.base =
        { pkgs, ... }:
        {
          nix = {
            enable = true;
            package = pkgs.nixVersions.${nixVersion};
            optimise.automatic = true;
            settings = config.nix.settings // {
              trusted-users = lib.mkBefore [ config.flake.meta.owner.username ];
            };

            gc = {
              automatic = true;
              interval.Day = 5;
              options = "--delete-older-than 1w";
            };
          };
        };

      # SUGGESTION
      # homeManager.base =
      #   { pkgs, ... }:
      #   {
      #     nix = {
      #       # forced because seems to be defined also in dotfiles at the time of writing this
      #       package = lib.mkForce pkgs.nixVersions.${nixVersion};
      #       inherit (config.nix) settings;
      #     };
      #   };

    };
  };
}
