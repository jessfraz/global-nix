{
  fetchurl,
  lib,
  stdenvNoCC,
}: let
  version = "4.1.0";
  sources = {
    aarch64-darwin = {
      url = "https://downloads.slack-edge.com/slack-cli/slack_cli_${version}_macOS_arm64.tar.gz";
      hash = "sha256-L9BqRKbkR4OvAv8qODYO+ov/TGFN0x9zhLny9auoTCk=";
    };
    x86_64-linux = {
      url = "https://downloads.slack-edge.com/slack-cli/slack_cli_${version}_linux_64-bit.tar.gz";
      hash = "sha256-AlWYTn2vKr39KK5zbADu75s0WMgcut7eSUjy8keP3vU=";
    };
  };
  source =
    sources.${stdenvNoCC.hostPlatform.system}
    or (throw "slack-cli is not packaged for ${stdenvNoCC.hostPlatform.system}");
in
  stdenvNoCC.mkDerivation {
    pname = "slack-cli";
    inherit version;

    src = fetchurl source;
    sourceRoot = ".";

    dontBuild = true;

    installPhase = ''
      runHook preInstall

      install -Dm755 bin/slack "$out/bin/slack"

      runHook postInstall
    '';

    meta = {
      description = "Official Slack command-line interface";
      homepage = "https://github.com/slackapi/slack-cli";
      license = lib.licenses.asl20;
      mainProgram = "slack";
      platforms = builtins.attrNames sources;
    };
  }
