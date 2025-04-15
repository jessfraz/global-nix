{ config, ... }:
{
  flake.modules.nixos.desktop.users.users.${config.flake.meta.owner.username}.extraGroups = [
    "libvirtd"
  ];
}
