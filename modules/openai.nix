{ lib, ... }:
{
  flake.modules.homeManager.base = {
    programs.bash.bashrcExtra = lib.mkOrder 700 ''
      function fetch-openai-key() {
          export OPENAI_API_KEY=$(op --account my.1password.com item get "openai.com" --fields apikey --reveal)
      }
    '';
  };
}
