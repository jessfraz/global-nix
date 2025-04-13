{ config, ... }:
{
  flake.modules.nixos."nixosConfigurations/system76".imports = with config.flake.modules.nixos; [
    desktop
    nvidia-gpu
  ];
}
