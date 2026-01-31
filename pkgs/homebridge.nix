{pkgs ? import <nixpkgs> {}}: let
  inherit (pkgs) buildNpmPackage fetchFromGitHub lib;
in
  buildNpmPackage rec {
    pname = "homebridge";
    version = "1.11.1";
    nodejs = pkgs.nodejs_22;
    gihubSha256 = "sha256-E21HowCRD78MZW3+um6vN5/NLncF/bt9v/Tw+RYe5xM=";

    src = fetchFromGitHub {
      owner = "homebridge";
      repo = "homebridge";
      rev = "v${version}";
      sha256 = gihubSha256;
    };

    # copy package-lock.json from the GitHub repo so buildNpmPackage is happy
    postPatch = ''
      cp ${fetchFromGitHub {
        owner = "homebridge";
        repo = "homebridge";
        rev = "v${version}";
        sha256 = gihubSha256;
      }}/package-lock.json ./package-lock.json
    '';

    production = false;

    # vendor the dependency tree
    npmDepsHash = "sha256-Da64zHwvX0W1viNhy4afr60onlWqbizaVox9Un6c65Y=";
    dontNpmBuild = true; # skip `npm run build`

    nativeBuildInputs = [pkgs.nodePackages.typescript];
    postBuild = ''
      echo "Running plain tsc…"
      tsc -p .
    '';

    # buildNpmPackage puts the CLI at $out/bin/homebridge automatically
    meta = with lib; {
      description = "Homebridge – HomeKit bridge";
      license = licenses.asl20;
      platforms = platforms.unix;
    };
  }
