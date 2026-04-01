{pkgs ? import <nixpkgs> {}}: let
  inherit (pkgs) buildNpmPackage fetchFromGitHub lib;
in
  buildNpmPackage rec {
    pname = "homebridge";
    version = "1.11.4";
    nodejs = pkgs.nodejs_22;
    gihubSha256 = "sha256-usp7zszkEfGsWXApywAolFhG0i59Pr/IvvaBMeU7YHc=";

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
    npmDepsHash = "sha256-Ci5aIDIEchB0niORK2cRy06qObLplCSogo6wRVXv9Vs=";
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
