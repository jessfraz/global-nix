{ lib, ... }:
{
  flake.modules.homeManager.base = {
    programs.bash.bashrcExtra = lib.mkOrder 900 ''
      function fetch-kc-token() {
          export KITTYCAD_TOKEN=$(op --account kittycadinc.1password.com item get --vault Employee "KittyCAD Token" --fields credential --reveal)
          export KITTYCAD_API_TOKEN=$KITTYCAD_TOKEN
          export KITTYCAD_DEV_TOKEN=$(op --account kittycadinc.1password.com item get --vault Employee "KittyCAD Dev Token" --fields credential --reveal)
      }
      alias fetch-zoo-token="fetch-kc-token"
      alias fetch-kittycad-token="fetch-kc-token"
    '';
  };
}
