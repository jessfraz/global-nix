{
  lib,
  stdenv,
}:
stdenv.mkDerivation {
  pname = "auto-dnd";
  version = "1.0.0";
  # Calendar selectors stay in ~/.config/auto-dnd/config.json, outside Nix.
  src = ../hosts/darwin/auto-dnd;
  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    $CC -Wall -Wextra -Werror -fobjc-arc -fblocks \
      -framework Foundation -framework AppKit -framework EventKit \
      main.m -o auto-dnd
    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    ./auto-dnd --test
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    app="$out/Applications/Auto DND.app/Contents"
    mkdir -p "$app/MacOS" "$app/Resources" "$out/bin"
    cp auto-dnd "$app/MacOS/auto-dnd"
    cp Info.plist "$app/Info.plist"
    cp shortcut.json "$app/Resources/shortcut.json"
    # Enter through the real app executable so NSBundle can find its resources.
    printf '#!%s\nexec "%s" "$@"\n' '${stdenv.shell}' "$app/MacOS/auto-dnd" > "$out/bin/auto-dnd"
    chmod +x "$out/bin/auto-dnd"
    runHook postInstall
  '';

  meta = {
    description = "Calendar-driven Do Not Disturb without Shortcuts polling";
    platforms = lib.platforms.darwin;
    mainProgram = "auto-dnd";
  };
}
