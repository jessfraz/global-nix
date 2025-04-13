{ config, ... }:
{
  flake.modules.darwin."darwinConfigurations/macinator" = {
    imports = [
      config.flake.modules.darwin.base
      config.flake.modules.darwin.gui
    ];

    home-manager.users.${config.flake.meta.owner.username}.imports = [
      config.flake.modules.homeManager.gui
    ];
  };
}
