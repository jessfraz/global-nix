{
  pkgs,
  lib,
  config,
  inputs,
  githubUsername,
  ...
}: let
  personal = item: field: env: {
    account = "my.1password.com";
    inherit item field env;
  };
  work = item: field: env: {
    account = "kittycadinc.1password.com";
    vault = "Employee";
    inherit item field env;
  };
  one = secret: {secrets = [secret];};
  launcher = pkgs.writeShellScriptBin "with-credentials" ''
    export PATH=${lib.makeBinPath [pkgs.python3 pkgs.gnupg pkgs.git pkgs.openssh pkgs._1password-cli inputs.switchboard.packages.${pkgs.stdenv.hostPlatform.system}.switchboard]}:$PATH
    exec ${pkgs.python3}/bin/python3 ${../../scripts/with-credentials.py} "$@"
  '';
  aliases = {
    fetch-github-token = "github.personal";
    fetch-gh-token = "github.personal";
    fetch-gws-personal = "google.personal";
    fetch-gws-work = "google.work";
    fetch-schwab-keys = "schwab.personal";
    fetch-openai-key = "openai";
    fetch-anthropic-key = "anthropic";
    fetch-google-ai-key = "google-ai";
    fetch-deepseek-key = "deepseek";
    fetch-grok-key = "grok";
    fetch-hf-key = "huggingface";
    fetch-kalshi-keys = "kalshi";
    fetch-unifi-keys = "unifi";
    fetch-unifi = "unifi";
    fetch-ubiquiti = "unifi";
    fetch-tailscale-key = "tailscale";
    fetch-home-assistant = "home-assistant";
    fetch-ha = "home-assistant";
    fetch-kc-token = "zoo";
    fetch-zoo-token = "zoo";
    fetch-kittycad-token = "zoo";
    fetch-pyx-token = "pyx";
    fetch-axiom-key = "axiom";
    fetch-easypost-keys = "easypost";
    fetch-stripe-key = "stripe";
    fetch-hoops-license = "hoops";
    fetch-kio-license = "kio";
    fetch-cockroach-license = "cockroach";
  };
in {
  programs.bash.bashrcExtra = ''
    source "${config.xdg.configHome}/with-credentials/shell.sh"
  '';
  programs.zsh.initContent = lib.mkIf config.programs.zsh.enable ''
    source "${config.xdg.configHome}/with-credentials/shell.sh"
  '';

  xdg.configFile."with-credentials/shell.sh".text =
    ''
      source ${../../scripts/credentials.sh}
    ''
    + lib.concatStringsSep "\n" (lib.mapAttrsToList (name: profile: ''
        function ${name}() {
          _fetch_credentials ${profile} "$@"
        }
      '')
      aliases);

  home.packages =
    [launcher]
    ++ lib.mapAttrsToList (name: profile:
      pkgs.writeShellScriptBin name ''
        exec ${launcher}/bin/with-credentials ${profile} -- "$@"
      '')
    aliases
    ++ [
      (pkgs.writeShellScriptBin "vault-login" ''
        exec ${launcher}/bin/with-credentials vault -- vault login -method=oidc "$@"
      '')
    ];

  xdg.configFile."with-credentials/profiles.json".text = builtins.toJSON {
    "github.personal" = {
      github_username = githubUsername;
      secrets = [(personal "GitHub Personal Access Token" "token" ["GITHUB_TOKEN" "GITHUB_PERSONAL_ACCESS_TOKEN"])];
    };
    "google.personal" = {
      environment.GOOGLE_WORKSPACE_CLI_CONFIG_DIR = "${config.home.homeDirectory}/.config/gws-personal";
      environment.GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND = "file";
      unset = ["GOOGLE_WORKSPACE_CLI_TOKEN" "GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE"];
      secrets = [
        (personal "gws cli" "username" ["GOOGLE_WORKSPACE_CLI_CLIENT_ID"])
        (personal "gws cli" "credential" ["GOOGLE_WORKSPACE_CLI_CLIENT_SECRET"])
      ];
    };
    "google.work" = {
      environment.GOOGLE_WORKSPACE_CLI_CONFIG_DIR = "${config.home.homeDirectory}/.config/gws-work";
      environment.GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND = "file";
      unset = ["GOOGLE_WORKSPACE_CLI_TOKEN" "GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE"];
      secrets = [
        (work "gws cli" "username" ["GOOGLE_WORKSPACE_CLI_CLIENT_ID"])
        (work "gws cli" "credential" ["GOOGLE_WORKSPACE_CLI_CLIENT_SECRET"])
      ];
    };
    "schwab.personal" = {
      environment.SCHWAB_CONFIG = "${config.home.homeDirectory}/.config/schwab-personal/config.json";
      secrets = [
        (personal "schwab cli" "username" ["SCHWAB_CLIENT_ID"])
        (personal "schwab cli" "credential" ["SCHWAB_CLIENT_SECRET"])
      ];
    };
    openai = one (personal "openai.com" "apikey" ["OPENAI_API_KEY"]);
    anthropic = one (personal "claude.ai" "apikey" ["ANTHROPIC_API_KEY"]);
    google-ai = one (personal "Google AI Studio" "credential" ["GOOGLE_API_KEY"]);
    deepseek = one (personal "deepseek.com" "apikey" ["DEEPSEEK_API_KEY"]);
    grok = one (personal "grok x.ai" "credential" ["GROK_API_KEY"]);
    huggingface = one (personal "huggingface.co" "apikey" ["HF_TOKEN"]);
    kalshi.secrets = [
      (personal "kalshi.com" "api-key-id" ["KALSHI_API_KEY_ID"])
      (personal "kalshi.com" "private-key" ["KALSHI_PRIVATE_KEY"])
    ];
    unifi.secrets = [
      (personal "ubnt.com" "home-api-key-network" ["UNIFI_NETWORK_API_KEY"])
      (personal "ubnt.com" "home-api-key-protect" ["UNIFI_PROTECT_API_KEY" "UNIFI_ACCESS_API_KEY"])
    ];
    tailscale = one (personal "tailscale.com" "apikey" ["TAILSCALE_API_KEY"]);
    home-assistant = {
      secrets = [
        (personal "5ggad4sew5hun2qpppoiu47xvu" null ["HOME_ASSISTANT_URL" "HASS_SERVER"]
          // {
            vault = "Private";
            url_label = "website";
            cache_file = "$XDG_CONFIG_HOME/home-assistant/url";
          })
        (personal "5ggad4sew5hun2qpppoiu47xvu" "apikey" ["HOME_ASSISTANT_TOKEN" "HASS_TOKEN"]
          // {
            vault = "Private";
            cache_file = "$XDG_CONFIG_HOME/home-assistant/token";
          })
      ];
    };
    zoo.secrets = [
      (work "KittyCAD Token" "credential" ["KITTYCAD_API_TOKEN" "ZOO_TOKEN" "ZOO_API_TOKEN" "ZOO_TEST_TOKEN"])
      (work "KittyCAD Dev Token" "credential" ["KITTYCAD_DEV_TOKEN"])
    ];
    pyx = one (work "pyx.dev Token" "credential" ["PYX_API_KEY"]);
    axiom = one (work "axiom.co" "apikey" ["AXIOM_TOKEN"]);
    easypost.secrets = [
      (work "easypost.com" "testkey" ["EASYPOST_TEST_API_KEY"])
      (work "easypost.com" "apikey" ["EASYPOST_API_KEY"])
    ];
    stripe = one ((work "stripe prod zoo" "credential" ["STRIPE_API_KEY"]) // {vault = null;});
    hoops = one ((work "Hoops Licence" "license key" ["HOOPS_LICENSE"]) // {vault = null;});
    kio = one ((work "3D_KERNEL_IO_LICENSE" "2025" ["KERNEL_IO_LICENSE"]) // {vault = null;});
    cockroach.secrets = [
      ((work "CockroachDB Dev License" "license key" ["COCKROACHDB_ENTERPRISE_LICENSE"]) // {vault = null;})
      ((work "CockroachDB Dev License" "certificate" [])
        // {
          vault = null;
          file_env = "DATABASE_ROOT_CERT_PATH";
          shell_file = "${config.home.homeDirectory}/.cockroach/ca.crt";
          strip_quotes = true;
        })
    ];
    vault.environment.VAULT_ADDR = "http://vault.hawk-dinosaur.ts.net";
  };
}
