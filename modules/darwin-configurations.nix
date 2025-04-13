{
  config,
  inputs,
  lib,
  ...
}:
let
  prefix = "darwinConfigurations/";
in
{
  flake = {
    darwinConfigurations =
      config.flake.modules.darwin or { }
      |> lib.filterAttrs (name: _module: lib.hasPrefix prefix name)
      |> lib.mapAttrs' (
        name: module:
        let
          hostName = lib.removePrefix prefix name;
        in
        {
          name = hostName;
          value = inputs.nix-darwin.lib.darwinSystem {
            modules = [
              module
              {
                networking = {
                  inherit hostName;
                  computerName = hostName;
                };
                system.defaults.smb = {
                  NetBIOSName = hostName;
                  ServerDescription = hostName;
                };
              }
            ];
          };
        }
      );
    checks =
      config.flake.darwinConfigurations
      |> lib.mapAttrsToList (
        name: nixos: {
          ${nixos.config.nixpkgs.hostPlatform.system} = {
            "${prefix}${name}" = nixos.config.system.build.toplevel;
          };
        }
      )
      |> lib.mkMerge;
  };
}
