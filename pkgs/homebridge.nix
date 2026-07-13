{pkgs ? import <nixpkgs> {}}: let
  inherit (pkgs) buildNpmPackage fetchFromGitHub lib;
in
  buildNpmPackage rec {
    pname = "homebridge";
    version = "2.1.1";
    nodejs = pkgs.nodejs_22;
    githubHash = "sha256-2u+hzNk3dAPeA7YzkJQNUCDmIpVybxp77JLKV9Nro/s=";

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
    npmDepsHash = "sha256-9dfXEJHMorDCl89UqGOfbQWf6ju+5AwhE3skhejtUuY=";
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
