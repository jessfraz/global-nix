{
  inputs,
  lib,
  config,
  ...
}:
{
  options.nixpkgs.allowUnfreePackages = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
  };

  config =
    let
      predicate = pkg: builtins.elem (lib.getName pkg) config.nixpkgs.allowUnfreePackages;
    in
    {
      perSystem =
        { system, ... }:
        {
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;
            config.allowUnfreePredicate = predicate;
          };
        };

      flake.modules = {
        nixos.desktop.nixpkgs.config.allowUnfreePredicate = predicate;

        homeManager.base = args: {
          nixpkgs.config = lib.mkIf (!(args.hasGlobalPkgs or false)) {
            allowUnfreePredicate = predicate;
          };
        };
      };
    };

}
