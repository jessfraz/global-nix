{config, ...}: {
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

      function fetch-openai-key() {
          export OPENAI_API_KEY=$(op --account my.1password.com item get "openai.com" --fields apikey --reveal)
      }

      function fetch-anthropic-key() {
          export ANTHROPIC_API_KEY=$(op --account my.1password.com item get "claude.ai" --fields apikey --reveal)
      }

      function fetch-kc-token() {
          export KITTYCAD_TOKEN=$(op --account kittycadinc.1password.com item get --vault Employee "KittyCAD Token" --fields credential --reveal)
          export KITTYCAD_DEV_TOKEN=$(op --account kittycadinc.1password.com item get --vault Employee "KittyCAD Dev Token" --fields credential --reveal)
      }

      function fetch-stripe-key() {
          export STRIPE_KEY=$(op --account kittycadinc.1password.com item get "stripe prod zoo" --fields credential --reveal)
      }

      function fetch-hoops-key() {
          export HOOPS_KEY=$(op --account kittycadinc.1password.com item get "Hoops Licence" --fields "new license key" --reveal)
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
