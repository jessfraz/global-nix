{ lib, ... }:
{
  flake.modules.homeManager.base =
    homeArgs:
    let
      inherit (homeArgs.config.home) homeDirectory;
    in
    {
      programs.bash.bashrcExtra = lib.mkOrder 1300 ''
        function fetch-cockroach-license() {
            export COCKROACHDB_ENTERPRISE_LICENSE=$(op --account kittycadinc.1password.com item get "CockroachDB Dev License" --fields "license key" --reveal)
            mkdir -p "${homeDirectory}/.cockroach"
            echo "$(op --account kittycadinc.1password.com item get "CockroachDB Dev License" --fields "certificate" --reveal)" > "${homeDirectory}/.cockroach/ca.crt"
            # Trim " from the file
            sed -i 's/^"//;s/"$//' ${homeDirectory}/.cockroach/ca.crt
            export DATABASE_ROOT_CERT_PATH="${homeDirectory}/.cockroach/ca.crt"
        }
      '';
    };
}
