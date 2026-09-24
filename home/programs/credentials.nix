{
  pkgs,
  lib,
  config,
  inputs,
  githubUsername,
  ...
}: let
  agent = item: field: env: {
    auth_profile = "personal";
    vault = "6f2yinpr4l6tp3qctbinvb3cky"; # AI Agents
    account = "my.1password.com";
    inherit item field env;
  };
  one = secret: {secrets = [secret];};
  zooProduction = agent "nfqecn7eeknmrhx7jddabwl2je" "credential" ["KITTYCAD_API_TOKEN" "ZOO_TOKEN" "ZOO_API_TOKEN" "ZOO_TEST_TOKEN"];
  zooDevelopment = agent "dfupwolg4uyy3maayex3h4pn7e" "credential" ["KITTYCAD_DEV_TOKEN"];
  easypostLive = agent "pfzeivkdscfyrilpbpurbstepe" "apikey" ["EASYPOST_API_KEY"];
  easypostTest = agent "pfzeivkdscfyrilpbpurbstepe" "testkey" ["EASYPOST_TEST_API_KEY"];
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
    fetch-unifi-keys = "unifi";
    fetch-unifi = "unifi";
    fetch-ubiquiti = "unifi";
    fetch-tailscale-key = "tailscale";
    fetch-home-assistant = "home-assistant";
    fetch-ha = "home-assistant";
    fetch-kc-token = "zoo";
    fetch-zoo-token = "zoo";
    fetch-zoo-prod-token = "zoo-prod";
    fetch-zoo-dev-token = "zoo-dev";
    fetch-kittycad-token = "zoo";
    fetch-axiom-key = "axiom";
    fetch-easypost-keys = "easypost";
    fetch-easypost-live-key = "easypost-live";
    fetch-easypost-test-key = "easypost-test";
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

  xdg.configFile."with-credentials/auth-profiles.json".text = builtins.toJSON {
    personal.token_file = "${config.xdg.configHome}/agent-credentials/personal.token";
  };

  xdg.configFile."with-credentials/profiles.json".text = builtins.toJSON {
    "github.personal" = {
      github_username = githubUsername;
      secrets = [(agent "xpm367ibuwilt4ocp63ht5cppq" "token" ["GITHUB_TOKEN" "GITHUB_PERSONAL_ACCESS_TOKEN"])];
    };
    "google.personal" = {
      environment.GOOGLE_WORKSPACE_CLI_CONFIG_DIR = "${config.home.homeDirectory}/.config/gws-personal";
      environment.GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND = "file";
      unset = ["GOOGLE_WORKSPACE_CLI_TOKEN" "GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE"];
      secrets = [
        (agent "ncsungf6iecce6ckmdm2n3v2ki" "username" ["GOOGLE_WORKSPACE_CLI_CLIENT_ID"])
        (agent "ncsungf6iecce6ckmdm2n3v2ki" "credential" ["GOOGLE_WORKSPACE_CLI_CLIENT_SECRET"])
      ];
    };
    "google.work" = {
      environment.GOOGLE_WORKSPACE_CLI_CONFIG_DIR = "${config.home.homeDirectory}/.config/gws-work";
      environment.GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND = "file";
      unset = ["GOOGLE_WORKSPACE_CLI_TOKEN" "GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE"];
      secrets = [
        (agent "bx3bb7ime32avadk4vs3tmvone" "username" ["GOOGLE_WORKSPACE_CLI_CLIENT_ID"])
        (agent "bx3bb7ime32avadk4vs3tmvone" "credential" ["GOOGLE_WORKSPACE_CLI_CLIENT_SECRET"])
      ];
    };
    "schwab.personal" = {
      environment.SCHWAB_CONFIG = "${config.home.homeDirectory}/.config/schwab-personal/config.json";
      secrets = [
        (agent "nyf64ypiujz6gqvrpgfj46wnbm" "username" ["SCHWAB_CLIENT_ID"])
        (agent "nyf64ypiujz6gqvrpgfj46wnbm" "credential" ["SCHWAB_CLIENT_SECRET"])
      ];
    };
    openai = one (agent "4h647lw22xr6jjsqokq2kaxb4a" "apikey" ["OPENAI_API_KEY"]);
    anthropic = one (agent "mj7p4uvfro3d7e6ispuyfv4x5i" "apikey" ["ANTHROPIC_API_KEY"]);
    google-ai = one (agent "r4lg7dwtp6kj4gb2zfcym234ai" "credential" ["GOOGLE_API_KEY"]);
    deepseek = one (agent "7brerhra2hwrnuvdq7jlacrcny" "apikey" ["DEEPSEEK_API_KEY"]);
    grok = one (agent "yufotbvsqml3lxcs5rkxmcsozu" "credential" ["GROK_API_KEY"]);
    unifi.secrets = [
      (agent "nn6rffzbcnxri5bwqly3xwj56u" "home-api-key-network" ["UNIFI_NETWORK_API_KEY"])
      (agent "nn6rffzbcnxri5bwqly3xwj56u" "home-api-key-protect" ["UNIFI_PROTECT_API_KEY" "UNIFI_ACCESS_API_KEY"])
    ];
    tailscale = one (agent "wtljtr2cgswlvjmxzjd7j7bph4" "apikey" ["TAILSCALE_API_KEY"]);
    home-assistant = {
      secrets = [
        (agent "ho3w66e4xvufb4sdg6e7ah2kuu" null ["HOME_ASSISTANT_URL" "HASS_SERVER"]
          // {
            url_label = "website";
          })
        (agent "ho3w66e4xvufb4sdg6e7ah2kuu" "apikey" ["HOME_ASSISTANT_TOKEN" "HASS_TOKEN"])
      ];
    };
    zoo.secrets = [zooProduction zooDevelopment];
    zoo-prod = one zooProduction;
    zoo-dev = one zooDevelopment;
    axiom = one (agent "7ilm4qrrg72ml2mjugjqtungzq" "apikey" ["AXIOM_TOKEN"]);
    easypost.secrets = [easypostTest easypostLive];
    easypost-live = one easypostLive;
    easypost-test = one easypostTest;
    stripe = one (agent "e7svort5v3ecjdy66xqw2hfzku" "credential" ["STRIPE_API_KEY"]);
    hoops = one (agent "ok3pjfwnhyknebpjvhlojql6e4" "license key" ["HOOPS_LICENSE"]);
    kio = one (agent "pxee7a46s3an46kx246z2lcu3y" "2025" ["KERNEL_IO_LICENSE"]);
    cockroach.secrets = [
      (agent "qlbznweqxz4jdaxyvyll67steq" "license key" ["COCKROACHDB_ENTERPRISE_LICENSE"])
      ((agent "qlbznweqxz4jdaxyvyll67steq" "certificate" [])
        // {
          file_env = "DATABASE_ROOT_CERT_PATH";
          shell_file = "${config.home.homeDirectory}/.cockroach/ca.crt";
          strip_quotes = true;
        })
    ];
    vault.environment.VAULT_ADDR = "http://vault.hawk-dinosaur.ts.net";
  };
}
