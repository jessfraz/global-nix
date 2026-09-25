{
  lib,
  stdenv,
  rustPlatform,
  src,
  pkg-config,
  fontconfig,
  freetype,
  libxkbcommon,
  wayland,
  libxcb,
  alsa-lib,
  openssl,
  zstd,
  vulkan-loader,
}:
rustPlatform.buildRustPackage {
  pname = "disktree";
  version = (builtins.fromTOML (builtins.readFile "${src}/Cargo.toml")).workspace.package.version;
  inherit src;

  cargoLock.lockFile = "${src}/Cargo.lock";
  cargoBuildFlags = ["--package=disktree-app"];
  # The filesystem tests run without a window server in the Nix sandbox.
  cargoTestFlags = ["--package=disktree-core"];

  nativeBuildInputs = [pkg-config];
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
    fontconfig
    freetype
    libxkbcommon
    wayland
    libxcb
    alsa-lib
    openssl
    zstd
  ];

  postInstall =
    lib.optionalString stdenv.hostPlatform.isDarwin ''
      app="$out/Applications/Disktree.app/Contents"
      mkdir -p "$app/MacOS"
      ln "$out/bin/disktree" "$app/MacOS/disktree"
      cat > "$app/Info.plist" <<EOF
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>
        <key>CFBundleName</key><string>Disktree</string>
        <key>CFBundleIdentifier</key><string>com.github.tobi.disktree</string>
        <key>CFBundleExecutable</key><string>disktree</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        <key>CFBundleVersion</key><string>$version</string>
        <key>CFBundleShortVersionString</key><string>$version</string>
        <key>NSHighResolutionCapable</key><true/>
      </dict></plist>
      EOF
    ''
    + lib.optionalString stdenv.hostPlatform.isLinux ''
      install -Dm644 assets/disktree.svg "$out/share/icons/hicolor/scalable/apps/disktree.svg"
      mkdir -p "$out/share/applications"
      substitute packaging/disktree.desktop.in "$out/share/applications/disktree.desktop" \
        --subst-var-by BINDIR "$out/bin" \
        --subst-var-by VERSION "$version"
    '';

  postFixup = lib.optionalString stdenv.hostPlatform.isLinux ''
    patchelf --add-rpath ${lib.makeLibraryPath [vulkan-loader wayland libxkbcommon]} "$out/bin/disktree"
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    "$out/bin/disktree" --help
    runHook postInstallCheck
  '';

  meta = {
    description = "Treemap explorer for disk usage";
    homepage = "https://github.com/tobi/disktree";
    license = lib.licenses.mit;
    mainProgram = "disktree";
    platforms = ["aarch64-darwin" "x86_64-linux"];
  };
}
