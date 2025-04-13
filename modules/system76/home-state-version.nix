{ config, ... }:
{
  # This value determines the Home Manager release that your configuration is
  # compatible with. This helps avoid breakage when a new Home Manager release
  # introduces backwards incompatible changes.
  #
  # You should not change this value, even if you update Home Manager. If you do
  # want to update the value, then make sure to first check the Home Manager
  # release notes.
  flake.modules.nixos."nixosConfigurations/system76".home-manager.users.${config.flake.meta.owner.username}.home.stateVersion =
    "25.05";
}
