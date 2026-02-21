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
      case ":$PATH:" in
          *":$HOME/.local/bin:"*)
              ;;
          *)
              unset __HM_SESS_VARS_SOURCED
              for hm_session_vars in \
                  "${config.home.profileDirectory}/etc/profile.d/hm-session-vars.sh" \
                  "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh"; do
                  if [ -r "$hm_session_vars" ]; then
                      # shellcheck disable=SC1090
                      . "$hm_session_vars"
                      break
                  fi
              done
              unset hm_session_vars
              ;;
      esac

      source ${config.home.homeDirectory}/.nixbash

      # Keep GPG_TTY aligned in interactive terminals.
      if [ -t 1 ]; then
          export GPG_TTY="$(tty)"
      fi

      # Avoid GUI prompts for 1Password CLI in SSH sessions.
      if [ -n "''${SSH_CONNECTION-}" ] || [ -n "''${SSH_TTY-}" ]; then
          if [ -z "''${OP_BIOMETRIC_UNLOCK_ENABLED-}" ]; then
              export OP_BIOMETRIC_UNLOCK_ENABLED=false
          fi
      fi

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

      function gcleanup() {
          local main
          main=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
          if [ -n "$main" ]; then
              main=$(cd "$main/.." && pwd -P)
          else
              main=$(git worktree list --porcelain | awk '$1=="worktree"{print $2; exit}')
          fi

          git cleanup || return $?

          if [ -n "$main" ]; then
              cd "$main" || return $?
          fi
      }

      function fetch-github-token() {
          op-ensure-session my.1password.com || return $?
          export GITHUB_TOKEN=$(op --account my.1password.com item get "GitHub Personal Access Token" --fields token --reveal)
          export GITHUB_PERSONAL_ACCESS_TOKEN=$GITHUB_TOKEN

          # Add the token to our .netrc file
          ${netRcContents}

          chmod 600 ~/.netrc

          # Add the token to our ~/.config/nix/nix.conf
          mkdir -p ~/.config/nix
          echo "access-tokens = github.com=$GITHUB_TOKEN" > ~/.config/nix/nix.conf
      }
      alias fetch-gh-token="fetch-github-token"

      function op-ensure-session() {
          local account="$1"
          if [ -z "$account" ]; then
              echo "op-ensure-session: missing account" >&2
              return 1
          fi
          if [ "''${OP_BIOMETRIC_UNLOCK_ENABLED-}" = "false" ]; then
              if ! op whoami --account "$account" >/dev/null 2>&1; then
                  eval "$(op signin --account "$account")" || return $?
              fi
          fi
      }

      function fetch-openai-key() {
          op-ensure-session my.1password.com || return $?
          export OPENAI_API_KEY=$(op --account my.1password.com item get "openai.com" --fields apikey --reveal)
      }

      function fetch-anthropic-key() {
          op-ensure-session my.1password.com || return $?
          export ANTHROPIC_API_KEY=$(op --account my.1password.com item get "claude.ai" --fields apikey --reveal)
      }

      function fetch-google-ai-key() {
          op-ensure-session my.1password.com || return $?
          export GOOGLE_API_KEY=$(op --account my.1password.com item get "Google AI Studio" --fields credential --reveal)
      }

      function fetch-deepseek-key() {
          op-ensure-session my.1password.com || return $?
          export DEEPSEEK_API_KEY=$(op --account my.1password.com item get "deepseek.com" --fields apikey --reveal)
      }

      function fetch-grok-key() {
          op-ensure-session my.1password.com || return $?
          export GROK_API_KEY=$(op --account my.1password.com item get "grok x.ai" --fields credential --reveal)
      }

      function fetch-hf-key() {
          op-ensure-session my.1password.com || return $?
          export HF_TOKEN=$(op --account my.1password.com item get "huggingface.co" --fields apikey --reveal)
      }

      function fetch-kalshi-keys() {
          op-ensure-session my.1password.com || return $?
          export KALSHI_API_KEY_ID=$(op --account my.1password.com item get "kalshi.com" --fields "api-key-id" --reveal)
          export KALSHI_PRIVATE_KEY=$(op --account my.1password.com item get "kalshi.com" --fields "private-key" --reveal)
      }

      function fetch-kc-token() {
          op-ensure-session kittycadinc.1password.com || return $?
          export KITTYCAD_API_TOKEN=$(op --account kittycadinc.1password.com item get --vault Employee "KittyCAD Token" --fields credential --reveal)
          export ZOO_TOKEN=$KITTYCAD_API_TOKEN
          export ZOO_API_TOKEN=$KITTYCAD_API_TOKEN
          export ZOO_TEST_TOKEN=$KITTYCAD_API_TOKEN
          export KITTYCAD_DEV_TOKEN=$(op --account kittycadinc.1password.com item get --vault Employee "KittyCAD Dev Token" --fields credential --reveal)
      }
      alias fetch-zoo-token="fetch-kc-token"
      alias fetch-kittycad-token="fetch-kc-token"

      function fetch-pyx-token() {
          op-ensure-session kittycadinc.1password.com || return $?
          export PYX_API_KEY=$(op --account kittycadinc.1password.com item get --vault Employee "pyx.dev Token" --fields credential --reveal)
      }

      function fetch-stripe-key() {
          op-ensure-session kittycadinc.1password.com || return $?
          export STRIPE_API_KEY=$(op --account kittycadinc.1password.com item get "stripe prod zoo" --fields credential --reveal)
      }

      function fetch-hoops-license() {
          op-ensure-session kittycadinc.1password.com || return $?
          export HOOPS_LICENSE=$(op --account kittycadinc.1password.com item get "Hoops Licence" --fields "license key" --reveal)
      }

      function fetch-kio-license() {
          op-ensure-session kittycadinc.1password.com || return $?
          export KERNEL_IO_LICENSE=$(op --account kittycadinc.1password.com item get "3D_KERNEL_IO_LICENSE" --fields "2025" --reveal)
      }

      function fetch-cockroach-license() {
          op-ensure-session kittycadinc.1password.com || return $?
          export COCKROACHDB_ENTERPRISE_LICENSE=$(op --account kittycadinc.1password.com item get "CockroachDB Dev License" --fields "license key" --reveal)
          mkdir -p "${config.home.homeDirectory}/.cockroach"
          echo "$(op --account kittycadinc.1password.com item get "CockroachDB Dev License" --fields "certificate" --reveal)" > "${config.home.homeDirectory}/.cockroach/ca.crt"
          # Trim " from the file
          sed -i 's/^"//;s/"$//' ${config.home.homeDirectory}/.cockroach/ca.crt
          export DATABASE_ROOT_CERT_PATH="${config.home.homeDirectory}/.cockroach/ca.crt"
      }

      function vault-login() {
          op-ensure-session kittycadinc.1password.com || return $?
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
