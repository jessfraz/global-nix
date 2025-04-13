{ lib, ... }:
{
  flake.modules.homeManager.base = {
    programs.bash.bashrcExtra = lib.mkOrder 1000 ''
      function fetch-stripe-key() {
          export STRIPE_API_KEY=$(op --account kittycadinc.1password.com item get "stripe prod zoo" --fields credential --reveal)
      }
    '';
  };
}
