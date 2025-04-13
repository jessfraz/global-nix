{ inputs, config, ... }:
{
  flake.modules.darwin.base = {
    imports = [ inputs.home-manager.darwinModules.home-manager ];
    home-manager = {
      useGlobalPkgs = true;
      extraSpecialArgs.hasGlobalPkgs = true;
      useUserPackages = true;

      users.${config.flake.meta.owner.username}.imports = [
        config.flake.modules.homeManager.base
      ];
    };
  };
}
