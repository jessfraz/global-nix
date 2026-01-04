{
  config,
  githubUsername,
  ...
}: let
  netRcContents = ''
    cat <<-EOF > ~/.netrc
    machine github.com
    login ${githubUsername}
    password $GITHUB_TOKEN

    machine api.github.com
    login ${githubUsername}
    password $GITHUB_TOKEN
    EOF
  '';
in {
  programs.bash = {
    enable = true;

    enableCompletion = true;

    shellOptions = [
      # check the window size after each command and, if necessary,
      # update the values of LINES and COLUMNS.
      "checkwinsize"
      # Case-insensitive globbing (used in pathname expansion)
      "nocaseglob"
      # Append to the Bash history file, rather than overwriting it
      "histappend"
      # Autocorrect typos in path names when using `cd`
      "cdspell"
      # `**/qux` will enter `./foo/bar/baz/qux`
      "autocd"
      # * Recursive globbing, e.g. `echo **/*.txt`
      "extglob"
      "globstar"
      # Warn if closing shell with running jobs.
      "checkjobs"
    ];

    historySize = 50000000;
    historyFileSize = 50000000;
    historyControl = ["ignoredups"];
    historyIgnore = ["exit"];

    # Load the other bash dotfiles we have.
    bashrcExtra = ''
      source ${config.home.homeDirectory}/.nixbash

      function wknew() {
          local b="$1"
          if [ -z "$b" ]; then
              echo "usage: wknew <branch>"
              return 1
          fi
          local repo wt
          repo=$(basename "$(git rev-parse --show-toplevel)") || return $?
          wt="../$repo-$b"
          git worktree add -b "$b" "$wt" origin/main || return $?
          git -C "$wt" submodule update --init --recursive || return $?
          git -C "$wt" config branch.$b.remote origin || return $?
          git -C "$wt" config branch.$b.merge refs/heads/$b || return $?
          cd "$wt" || return $?
      }

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

      function fetch-openai-key() {
          export OPENAI_API_KEY=$(op --account my.1password.com item get "openai.com" --fields apikey --reveal)
      }

      function fetch-anthropic-key() {
          export ANTHROPIC_API_KEY=$(op --account my.1password.com item get "claude.ai" --fields apikey --reveal)
      }

      function fetch-google-ai-key() {
          export GOOGLE_API_KEY=$(op --account my.1password.com item get "Google AI Studio" --fields credential --reveal)
      }

      function fetch-deepseek-key() {
          export DEEPSEEK_API_KEY=$(op --account my.1password.com item get "deepseek.com" --fields apikey --reveal)
      }

      function fetch-grok-key() {
          export GROK_API_KEY=$(op --account my.1password.com item get "grok x.ai" --fields credential --reveal)
      }

      function fetch-hf-key() {
          export HF_TOKEN=$(op --account my.1password.com item get "huggingface.co" --fields apikey --reveal)
      }

      function fetch-kc-token() {
          export KITTYCAD_API_TOKEN=$(op --account kittycadinc.1password.com item get --vault Employee "KittyCAD Token" --fields credential --reveal)
          export ZOO_TOKEN=$KITTYCAD_API_TOKEN
          export ZOO_API_TOKEN=$KITTYCAD_API_TOKEN
          export ZOO_TEST_TOKEN=$KITTYCAD_API_TOKEN
          export KITTYCAD_DEV_TOKEN=$(op --account kittycadinc.1password.com item get --vault Employee "KittyCAD Dev Token" --fields credential --reveal)
      }
      alias fetch-zoo-token="fetch-kc-token"
      alias fetch-kittycad-token="fetch-kc-token"

      function fetch-pyx-token() {
          export PYX_API_KEY=$(op --account kittycadinc.1password.com item get --vault Employee "pyx.dev Token" --fields credential --reveal)
      }

      function fetch-stripe-key() {
          export STRIPE_API_KEY=$(op --account kittycadinc.1password.com item get "stripe prod zoo" --fields credential --reveal)
      }

      function fetch-hoops-license() {
          export HOOPS_LICENSE=$(op --account kittycadinc.1password.com item get "Hoops Licence" --fields "license key" --reveal)
      }

      function fetch-kio-license() {
          export KERNEL_IO_LICENSE=$(op --account kittycadinc.1password.com item get "3D_KERNEL_IO_LICENSE" --fields "2025" --reveal)
      }

      function fetch-cockroach-license() {
          export COCKROACHDB_ENTERPRISE_LICENSE=$(op --account kittycadinc.1password.com item get "CockroachDB Dev License" --fields "license key" --reveal)
          mkdir -p "${config.home.homeDirectory}/.cockroach"
          echo "$(op --account kittycadinc.1password.com item get "CockroachDB Dev License" --fields "certificate" --reveal)" > "${config.home.homeDirectory}/.cockroach/ca.crt"
          # Trim " from the file
          sed -i 's/^"//;s/"$//' ${config.home.homeDirectory}/.cockroach/ca.crt
          export DATABASE_ROOT_CERT_PATH="${config.home.homeDirectory}/.cockroach/ca.crt"
      }

      function vault-login() {
          export VAULT_ADDR="http://vault.hawk-dinosaur.ts.net"
          export GITHUB_VAULT_TOKEN=$(op --account kittycadinc.1password.com item get --vault Employee "GitHub Token Vault" --fields credential --reveal)
          echo $GITHUB_VAULT_TOKEN | vault login -method=github token=-
      }
    '';

    # Fix for https://github.com/nix-community/home-manager/issues/5997
    initExtra = ''
      gpgconf --launch gpg-agent
    '';
    sessionVariables = {
      SSH_AUTH_SOCK = "$(gpgconf --list-dirs agent-ssh-socket)";
    };
  };
}
