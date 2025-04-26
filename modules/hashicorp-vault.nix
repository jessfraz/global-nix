{ lib, ... }:
{
  flake.modules.homeManager.base = {
    programs.bash.bashrcExtra = lib.mkOrder 1400 ''
      function vault-login() {
          export VAULT_ADDR="http://vault.hawk-dinosaur.ts.net"
          export GITHUB_VAULT_TOKEN=$(op --account kittycadinc.1password.com item get --vault Employee "GitHub Token Vault" --fields credential --reveal)
          echo $GITHUB_VAULT_TOKEN | vault login -method=github token=-
      }
    '';
  };
}
