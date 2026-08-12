{pkgs ? import <nixpkgs> {}}: let
  inherit (pkgs) buildNpmPackage fetchFromGitHub lib;
in
  buildNpmPackage rec {
    pname = "homebridge";
    version = "2.3.1";
    nodejs = pkgs.nodejs_22;
    githubHash = "sha256-5hJw+3hlEWjibd8GQZ0fTofFNWEplBg6/LkvudpbgEM=";

    src = fetchFromGitHub {
      owner = "homebridge";
      repo = "homebridge";
      rev = "v${version}";
      sha256 = githubHash;
    };

    # copy package-lock.json from the GitHub repo so buildNpmPackage is happy
    postPatch = ''
      cp ${fetchFromGitHub {
        owner = "homebridge";
        repo = "homebridge";
        rev = "v${version}";
        sha256 = githubHash;
      }}/package-lock.json ./package-lock.json
    '';

    production = false;

    # vendor the dependency tree
    npmDepsHash = "sha256-csYFg6sl5AWM073Hf9tD/a4D2AHG/Wi2HXMPUC94D1I=";
    dontNpmBuild = true; # skip `npm run build`
    postBuild = ''
      # Homebridge ships its own pinned TypeScript, so use that instead of the
      # removed nixpkgs `nodePackages` set.
      echo "Running vendored tsc..."
      ./node_modules/.bin/tsc -p .
    '';

    # buildNpmPackage puts the CLI at $out/bin/homebridge automatically
    meta = with lib; {
      description = "Homebridge – HomeKit bridge";
      license = licenses.asl20;
      platforms = platforms.unix;
    };
  }
