{
  lib,
  stdenvNoCC,
  fetchurl,
  _7zz,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "orca-slicer-bin";
  version = "2.5.0";

  src = fetchurl {
    url = "https://github.com/OrcaSlicer/OrcaSlicer/releases/download/v${finalAttrs.version}/OrcaSlicer_Mac_universal_V${finalAttrs.version}.dmg";
    hash = "sha256-Bh4Mb/EEw3ZVyDGQclrCQglg8jw5tWqum1RubFQpldU=";
  };

  # The release DMG uses APFS; preserve the bundle's framework symlinks.
  nativeBuildInputs = [_7zz];
  sourceRoot = ".";
  unpackCmd = "7zz x -snld $curSrc";

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/Applications" "$out/bin"
    cp -R OrcaSlicer.app "$out/Applications/OrcaSlicer.app"
    ln -s "$out/Applications/OrcaSlicer.app/Contents/MacOS/OrcaSlicer" "$out/bin/orca-slicer"

    runHook postInstall
  '';

  # Preserve the upstream application bundle and its code signature.
  dontFixup = true;

  meta = {
    description = "G-code generator for 3D printers";
    homepage = "https://github.com/OrcaSlicer/OrcaSlicer";
    license = lib.licenses.agpl3Only;
    mainProgram = "orca-slicer";
    platforms = lib.platforms.darwin;
    sourceProvenance = with lib.sourceTypes; [binaryNativeCode];
  };
})
