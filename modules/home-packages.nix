# SUGGESTION: rm this module and use home-manager's `home.packages` option instead
{
  getSystem,
  lib,
  flake-parts-lib,
  ...
}:
{
  options.perSystem = flake-parts-lib.mkPerSystemOption {
    options.home-packages-gui = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
    };
  };

  config = {
    perSystem =
      perSystemArgs@{ pkgs, ... }:
      {
        packages.default = pkgs.buildEnv {
          name = "home-packages";
          paths = perSystemArgs.config.home-packages-gui;
        };
      };

    flake.modules = {
      nixos.desktop =
        { pkgs, ... }:
        {
          environment.systemPackages = [ (getSystem pkgs.system).packages.default ];
        };

      darwin.gui =
        { pkgs, ... }:
        {
          environment.systemPackages = lib.mkAfter [ (getSystem pkgs.system).packages.default ];
        };
    };

  };
}
