{
  lib,
  stdenvNoCC,
  fetchurl,
  python3,
  version,
  upstreamSource,
}: let
  releases = {
    aarch64-darwin = {
      target = "aarch64-apple-darwin";
      hash = "sha256-iON8zd9aD06p3BvhPGaiqU+cLRoE86zpBT1xs5OeiF0=";
    };
    x86_64-linux = {
      target = "x86_64-unknown-linux-musl";
      hash = "sha256-pnb1ciquDYbL43ZDMvCOqx/didwKMAs61P+/SGEfo+M=";
    };
  };
  release = releases.${stdenvNoCC.hostPlatform.system};
in
  stdenvNoCC.mkDerivation {
    pname = "codex";
    inherit version;
    src = fetchurl {
      url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-package-${release.target}.tar.gz";
      inherit (release) hash;
    };

    dontUnpack = true;
    # Keep macOS signatures and the Linux sandbox's embedded helper hash intact.
    dontFixup = true;
    nativeInstallCheckInputs = [python3];
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      tar -xzf "$src" -C "$out"
      runHook postInstall
    '';

    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      python3 ${../scripts/check-codex-package.py} --layout-only "$out" "${version}" "${upstreamSource}"
      runHook postInstallCheck
    '';

    passthru = {inherit upstreamSource;};

    meta = {
      description = "OpenAI Codex CLI with its complete upstream runtime package";
      homepage = "https://github.com/openai/codex";
      license = lib.licenses.asl20;
      mainProgram = "codex";
      platforms = builtins.attrNames releases;
    };
  }
