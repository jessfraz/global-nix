{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  fetchzip,
  makeWrapper,
  bashInteractive,
}: let
  version = "1.25.0";
  tag = "V${version}";
  srcHash = "sha256-THZHQUE3l1G4U6eoY4/CPt7auyqs0eGP8+uHFpZrfNs=";
  binariesHashArm64 = "sha256-ZDGJ0l0aCpQyRST0krgU/llwR64tWtMLHAv84SZi4i8=";
  binariesHashAmd64 = "sha256-7N5yTDO8iKsqBxt15338rRsREm92uwdy2ZHHPpx5vsI=";

  archSuffix =
    if stdenvNoCC.hostPlatform.isAarch64
    then "arm64"
    else "amd64";

  binariesHash =
    if stdenvNoCC.hostPlatform.isAarch64
    then binariesHashArm64
    else binariesHashAmd64;

  src = fetchFromGitHub {
    owner = "tw93";
    repo = "Mole";
    rev = tag;
    hash = srcHash;
  };

  binSrc = fetchzip {
    url = "https://github.com/tw93/Mole/releases/download/${tag}/binaries-darwin-${archSuffix}.tar.gz";
    hash = binariesHash;
    stripRoot = false;
  };
in
  stdenvNoCC.mkDerivation {
    pname = "mole";
    inherit version src;

    nativeBuildInputs = [makeWrapper bashInteractive];
    dontBuild = true;
    dontPatchShebangs = true;

    installPhase = ''
      runHook preInstall

      install -d "$out/share/mole"
      cp -R "$src"/{mole,mo,lib,LICENSE,README.md} "$out/share/mole/"

      install -d "$out/share/mole/bin"
      if [ -d "$src/bin" ]; then
        cp -R "$src/bin/"* "$out/share/mole/bin/"
        find "$out/share/mole/bin" -type f -exec chmod +x {} +
      fi

      cp -f "${binSrc}/analyze-darwin-${archSuffix}" "$out/share/mole/bin/analyze-go"
      cp -f "${binSrc}/status-darwin-${archSuffix}" "$out/share/mole/bin/status-go"
      chmod +x "$out/share/mole/bin/analyze-go" "$out/share/mole/bin/status-go"

      chmod +x "$out/share/mole/mole" "$out/share/mole/mo"

      install -d "$out/bin"
      makeWrapper "$out/share/mole/mole" "$out/bin/mole"
      makeWrapper "$out/share/mole/mo" "$out/bin/mo"

      # Use bashInteractive so builtins like compgen exist in Mole's scripts.
      export PATH="${bashInteractive}/bin:$PATH"
      patchShebangs "$out/share/mole" "$out/bin"

      runHook postInstall
    '';

    meta = with lib; {
      description = "Mac cleanup and optimization tool";
      homepage = "https://github.com/tw93/Mole";
      license = licenses.mit;
      platforms = platforms.darwin;
      mainProgram = "mo";
    };
  }
