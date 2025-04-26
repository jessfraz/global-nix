{ config, ... }:
{
  flake.modules.darwin."darwinConfigurations/macinator" = {
    # Used for backwards compatibility, please read the changelog before changing.
    # $ darwin-rebuild changelog
    system.stateVersion = 6;

    # It is occasionally necessary for Home Manager to change configuration defaults in a way that is incompatible with stateful data. This could, for example, include switching the default data format or location of a file.
    # The state version indicates which default settings are in effect and will therefore help avoid breaking program configurations. Switching to a higher state version typically requires performing some manual steps, such as data conversion or moving files.
    home-manager.users.${config.flake.meta.owner.username}.home.stateVersion = "25.05";
  };
}
