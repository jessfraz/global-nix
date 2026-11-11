{
  lib,
  stdenvNoCC,
  fetchurl,
  undmg,
  makeWrapper,
  libredwg,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "freecad-bin";
  version = "1.1.4";

  src = fetchurl {
    url = "https://github.com/FreeCAD/FreeCAD/releases/download/${finalAttrs.version}/FreeCAD_${finalAttrs.version}-macOS-arm64-py311.dmg";
    hash = "sha256-BxNDtKu3BJK3XJc/Qerx0lKPm5x+oBjSKk9GrhTSesA=";
  };

  nativeBuildInputs = [undmg makeWrapper];
  sourceRoot = ".";

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/share/freecad" "$out/bin"
    cp -R FreeCAD.app "$out/share/freecad/FreeCAD.app"
    bundle="$out/share/freecad/FreeCAD.app"
    resources="$bundle/Contents/Resources"

    # The upstream launcher prints its environment. Invoke the bundled binaries
    # directly with the same runtime paths, keeping credentials out of logs.
    for binary in freecad freecadcmd; do
      makeWrapper "$resources/bin/$binary" "$out/bin/$binary" \
        --prefix PATH : ${lib.makeBinPath [libredwg]} \
        --set PREFIX "$resources" \
        --set PYTHONHOME "$resources" \
        --set PYTHONPATH "$resources" \
        --set LD_LIBRARY_PATH "$resources/lib" \
        --set FONTCONFIG_FILE /etc/fonts/fonts.conf \
        --set FONTCONFIG_PATH /etc/fonts \
        --set LANG UTF-8 \
        --set SSL_CERT_FILE "$resources/ssl/cacert.pem" \
        --set GIT_SSL_CAINFO "$resources/ssl/cacert.pem"
    done

    # Finder and Dock launches need the same converter and runtime environment.
    # Keep the signed upstream payload intact behind a small launcher bundle.
    app="$out/Applications/FreeCAD.app/Contents"
    mkdir -p "$app/MacOS"
    cp "$bundle/Contents/Info.plist" "$app/Info.plist"
    ln -s "$resources" "$app/Resources"
    makeWrapper "$out/bin/freecad" "$app/MacOS/FreeCAD"

    runHook postInstall
  '';

  # Preserve the signed upstream bundle and its relative library paths.
  dontFixup = true;

  meta = {
    description = "Parametric 3D CAD modeler with BIM and technical drawing tools";
    homepage = "https://www.freecad.org/";
    license = lib.licenses.lgpl2Plus;
    mainProgram = "freecad";
    platforms = ["aarch64-darwin"];
    sourceProvenance = with lib.sourceTypes; [binaryNativeCode];
  };
})
