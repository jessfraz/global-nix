{ lib, ... }:
{
  flake.modules.homeManager.base = {
    programs.bash.bashrcExtra = lib.mkOrder 1100 ''
      function fetch-hoops-license() {
          export HOOPS_LICENSE=$(op --account kittycadinc.1password.com item get "Hoops Licence" --fields "new license key" --reveal)
      }
    '';
  };
}
