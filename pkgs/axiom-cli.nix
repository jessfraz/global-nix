{
  fetchzip,
  lib,
  stdenvNoCC,
}: let
  version = "0.16.0";
  sources = {
    aarch64-darwin = {
      url = "https://github.com/axiomhq/cli/releases/download/v${version}/axiom_${version}_darwin_arm64.tar.gz";
      hash = "sha256-gQSYjTuPGnqu6mPoJuChOQoI30PbS+cop66coDyY9KE=";
    };
    x86_64-linux = {
      url = "https://github.com/axiomhq/cli/releases/download/v${version}/axiom_${version}_linux_amd64.tar.gz";
      hash = "sha256-PYVIljF7SCGXcLtqabpPudc608wUER9jGyyPtl82CCI=";
    };
  };
  source =
    sources.${stdenvNoCC.hostPlatform.system}
    or (throw "axiom-cli is not packaged for ${stdenvNoCC.hostPlatform.system}");
in
  stdenvNoCC.mkDerivation {
    pname = "axiom-cli";
    inherit version;

    src = fetchzip source;

    dontBuild = true;

    installPhase = ''
      runHook preInstall

      install -Dm755 axiom "$out/bin/axiom"
      install -Dm644 LICENSE "$out/share/licenses/axiom-cli/LICENSE"

      install -d "$out/share/man/man1"
      install -m644 man/*.1 "$out/share/man/man1/"

      install -Dm644 completions/axiom.bash "$out/share/bash-completion/completions/axiom"
      install -Dm644 completions/_axiom "$out/share/zsh/site-functions/_axiom"
      install -Dm644 completions/axiom.fish "$out/share/fish/vendor_completions.d/axiom.fish"

      runHook postInstall
    '';

    meta = {
      description = "Official Axiom command-line interface";
      homepage = "https://github.com/axiomhq/cli";
      license = lib.licenses.mit;
      mainProgram = "axiom";
      platforms = builtins.attrNames sources;
    };
  }
