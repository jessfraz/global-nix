{
  self,
  lib,
  runCommand,
}: let
  hasKiCad = lib.any (package: lib.hasPrefix "kicad" (package.pname or package.name));
  hasOrcaSlicer = lib.any (package: lib.hasPrefix "orca-slicer" (package.pname or package.name));
  hasHaClis = system: packages:
    lib.all (name: lib.any (package: package.outPath == self.packages.${system}.${name}.outPath) packages)
    ["ha-shipments" "ha-maintenance" "ha-filevault"];
  hasSharedBundle = system: packages:
    lib.any (package: package.outPath == self.packages.${system}.default.outPath) packages;
  sharedPackages = self.packages.aarch64-darwin.default.paths;
  laptopPackages = self.darwinConfigurations.macinator.config.environment.systemPackages;
  serverPackages = self.darwinConfigurations.macmini.config.environment.systemPackages;
  linuxPackages = self.nixosConfigurations.system76.config.environment.systemPackages;
in
  assert hasHaClis "aarch64-darwin" sharedPackages;
  assert hasHaClis "x86_64-linux" self.packages.x86_64-linux.default.paths;
  assert hasSharedBundle "aarch64-darwin" laptopPackages;
  assert hasSharedBundle "aarch64-darwin" serverPackages;
  assert hasSharedBundle "x86_64-linux" linuxPackages;
  assert !hasKiCad sharedPackages;
  assert hasKiCad laptopPackages;
  assert !hasKiCad serverPackages;
  assert hasKiCad linuxPackages;
  assert !hasOrcaSlicer sharedPackages;
  assert hasOrcaSlicer laptopPackages;
  assert !hasOrcaSlicer serverPackages;
  assert !hasOrcaSlicer linuxPackages;
    runCommand "package-selection-check" {} ''
      touch "$out"
    ''
