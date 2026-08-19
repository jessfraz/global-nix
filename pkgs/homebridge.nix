{pkgs ? import <nixpkgs> {}}: let
  inherit (pkgs) buildNpmPackage fetchFromGitHub lib;
in
  buildNpmPackage rec {
    pname = "homebridge";
    version = "2.4.0";
    nodejs = pkgs.nodejs_22;
    githubHash = "sha256-S0dm95lqPNgZtueCSZQWxHmYfMIpgbJi+Rs/ClGnrRk=";

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
    npmDepsHash = "sha256-uUSUt0TjaO8rh3K/Ob7syBDboISTVRRcvgWKD+VVHkU=";
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
