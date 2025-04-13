{ lib, ... }:
{
  flake.modules.homeManager.base = {
    programs.bash.bashrcExtra = lib.mkOrder 1100 ''
      function fetch-hoops-key() {
          export HOOPS_KEY=$(op --account kittycadinc.1password.com item get "Hoops Licence" --fields "new license key" --reveal)
      }
    '';
  };
}
