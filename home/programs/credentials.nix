{
  pkgs,
  lib,
  config,
  inputs,
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
  home.packages =
    [launcher]
    ++ lib.mapAttrsToList (name: profile:
      pkgs.writeShellScriptBin name ''
        exec ${launcher}/bin/with-credentials ${profile} -- "$@"
      '')
    aliases
    ++ [
      (pkgs.writeShellScriptBin "vault-login" ''
        exec ${launcher}/bin/with-credentials vault -- ${pkgs.bash}/bin/bash -c \
          'printf "%s" "$GITHUB_VAULT_TOKEN" | vault login -method=github token=-'
      '')
    ];

  xdg.configFile."with-credentials/profiles.json".text = builtins.toJSON {
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
        (personal "5ggad4sew5hun2qpppoiu47xvu" "website" ["HOME_ASSISTANT_URL" "HASS_SERVER"]
          // {
            vault = "Private";
            cache_file = "${config.home.homeDirectory}/.config/home-assistant/url";
          })
        (personal "5ggad4sew5hun2qpppoiu47xvu" "apikey" ["HOME_ASSISTANT_TOKEN" "HASS_TOKEN"]
          // {
            vault = "Private";
            cache_file = "${config.home.homeDirectory}/.config/home-assistant/token";
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
          strip_quotes = true;
        })
    ];
    vault = {
      environment.VAULT_ADDR = "http://vault.hawk-dinosaur.ts.net";
      secrets = [(work "GitHub Token Vault" "credential" ["GITHUB_VAULT_TOKEN"])];
    };
  };
}
