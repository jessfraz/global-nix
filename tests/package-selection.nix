{
  self,
  lib,
  runCommand,
}: let
  hasKiCad = lib.any (package: lib.hasPrefix "kicad" (package.pname or package.name));
  sharedPackages = self.packages.aarch64-darwin.default.paths;
  laptopPackages = self.darwinConfigurations.macinator.config.environment.systemPackages;
  serverPackages = self.darwinConfigurations.macmini.config.environment.systemPackages;
  linuxPackages = self.nixosConfigurations.system76.config.environment.systemPackages;
in
  assert !hasKiCad sharedPackages;
  assert hasKiCad laptopPackages;
  assert !hasKiCad serverPackages;
  assert hasKiCad linuxPackages;
    runCommand "package-selection-check" {} ''
      touch "$out"
    ''
