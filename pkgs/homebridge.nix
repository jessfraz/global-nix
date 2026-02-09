{pkgs ? import <nixpkgs> {}}: let
  inherit (pkgs) buildNpmPackage fetchFromGitHub lib;
in
  buildNpmPackage rec {
    pname = "homebridge";
    version = "1.11.2";
    nodejs = pkgs.nodejs_22;
    gihubSha256 = "sha256-6w2SDnP7P89j3/oLR77D0ubOzDb93krrRJQsDrhPTR4=";

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
    npmDepsHash = "sha256-m6ZLwDyWEwll7PYRHREThj+SvkfCNgODrpo8DTk6j8w=";
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
