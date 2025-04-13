{ lib, ... }:
{
  flake.modules.homeManager.base =
    let
      netRcContents = ''
        cat <<-EOF > ~/.netrc
        machine github.com
        login jessfraz
        password $GITHUB_TOKEN

        machine api.github.com
        login jessfraz
        password $GITHUB_TOKEN
        EOF
      '';
    in
    {
      programs = {
        bash.bashrcExtra = lib.mkOrder 600 ''
          function fetch-github-token() {
              export GITHUB_TOKEN=$(op --account my.1password.com item get "GitHub Personal Access Token" --fields token --reveal)

              # Add the token to our .netrc file
              ${netRcContents}

              chmod 600 ~/.netrc

              # Add the token to our ~/.config/nix/nix.conf
              mkdir -p ~/.config/nix
              echo "access-tokens = github.com=$GITHUB_TOKEN" > ~/.config/nix/nix.conf
          }
          alias fetch-gh-token="fetch-github-token"
        '';

        git.extraConfig = {
          github.user = "jessfraz";

          url = {
            "git@github.com:github" = {
              insteadOf = [
                "https://github.com/github"
                "github:github"
                "git://github.com/github"
              ];
            };
            "git@github.com:" = {
              pushInsteadOf = [
                "https://github.com/"
                "github:"
                "git://github.com/"
              ];
            };
            "git://github.com/" = {
              insteadOf = "github:";
            };
            "git@gist.github.com:" = {
              insteadOf = "gst:";
              pushInsteadOf = [
                "gist:"
                "git://gist.github.com/"
              ];
            };
            "git://gist.github.com/" = {
              insteadOf = "gist:";
            };
          };
        };
      };
    };
}
