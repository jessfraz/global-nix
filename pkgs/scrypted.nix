{pkgs ? import <nixpkgs> {}}: let
  inherit (pkgs) buildNpmPackage fetchFromGitHub lib;
  version = "0.139.0";
  gitHubSha256 = "sha256-LrT0wQ7LpKuUy3Ys7jvJHe+gZVBnztdr1A6lEg3cMGU=";
in
  buildNpmPackage rec {
    pname = "scrypted";
    inherit version;

    src = fetchFromGitHub {
      owner = "koush";
      repo = "scrypted";
      rev = "v${version}";
      sha256 = gitHubSha256;
    };

    # copy package-lock.json from the GitHub repo so buildNpmPackage is happy
    postPatch = ''
      cp -r ${fetchFromGitHub {
        owner = "koush";
        repo = "scrypted";
        rev = "v${version}";
        sha256 = gitHubSha256;
      }}/server/package.json ./package.json

      cp -r ${fetchFromGitHub {
        owner = "koush";
        repo = "scrypted";
        rev = "v${version}";
        sha256 = gitHubSha256;
      }}/server/package-lock.json ./package-lock.json
    '';

    production = false;

    # tool-chain for node-gyp native builds
    nativeBuildInputs = [
      pkgs.clang
      pkgs.python3
      pkgs.nodePackages.node-gyp # wrapper that pulls gyp.js & friends
      pkgs.make
      pkgs.nodePackages.typescript
    ];

    npmBuildScript = "npm --prefix server run build";

    npmDepsHash = "sha256-37W9j5QhGC942TJqIQEscypMtFi5teEEUygYg+j/7j8=";

    meta = with lib; {
      description = "Scrypted smart-home / camera bridge";
      homepage = "https://github.com/koush/scrypted";
      license = licenses.asl20;
      platforms = platforms.unix;
    };
  }
