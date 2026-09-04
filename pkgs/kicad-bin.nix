{
  lib,
  stdenvNoCC,
  fetchurl,
  undmg,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "kicad-bin";
  version = "10.0.6";

  src = fetchurl {
    url = "https://github.com/KiCad/kicad-source-mirror/releases/download/${finalAttrs.version}/kicad-unified-universal-${finalAttrs.version}.dmg";
    hash = "sha256-703NQnjEbT780oyNsnPVlX1o79oCj2v3m0gR/FMC3Gg=";
  };

  nativeBuildInputs = [undmg];
  sourceRoot = ".";

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/Applications" "$out/bin"
    cp -R KiCad "$out/Applications/KiCad"

    for binary in dxf2idf idf2vrml idfcyl idfrect kicad-cli; do
      ln -s "$out/Applications/KiCad/KiCad.app/Contents/MacOS/$binary" "$out/bin/$binary"
    done

    runHook postInstall
  '';

  # Preserve the upstream notarized application bundle.
  dontFixup = true;

  meta = {
    description = "Open Source Electronics Design Automation suite";
    homepage = "https://www.kicad.org/";
    license = lib.licenses.gpl3Plus;
    mainProgram = "kicad-cli";
    platforms = lib.platforms.darwin;
    sourceProvenance = with lib.sourceTypes; [binaryNativeCode];
  };
})
