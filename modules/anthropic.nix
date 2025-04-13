{ lib, ... }:
{
  flake.modules.homeManager.base = {
    programs.bash.bashrcExtra = lib.mkOrder 800 ''
      function fetch-anthropic-key() {
          export ANTHROPIC_API_KEY=$(op --account my.1password.com item get "claude.ai" --fields apikey --reveal)
      }
    '';
  };
}
