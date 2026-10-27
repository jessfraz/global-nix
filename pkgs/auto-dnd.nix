{
  lib,
  stdenv,
  workCalendar,
  personalAccount,
}: let
  config = builtins.toJSON {inherit workCalendar personalAccount;};
in
  stdenv.mkDerivation {
    pname = "auto-dnd";
    version = "1.0.0";
    # This configured app belongs to the host, outside the public package cache.
    preferLocalBuild = true;
    allowSubstitutes = false;
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
      cp ${builtins.toFile "auto-dnd-config.json" config} "$app/Resources/config.json"
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
