{
  flake.modules.nixos.desktop =
    { pkgs, ... }:
    {
      boot.kernelPackages = pkgs.linuxPackages;
    };
}
