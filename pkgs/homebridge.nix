{pkgs ? import <nixpkgs> {}}: let
  inherit (pkgs) buildNpmPackage fetchFromGitHub lib;
in
  buildNpmPackage rec {
    pname = "homebridge";
    version = "1.10.0";

    src = fetchFromGitHub {
      owner = "homebridge";
      repo = "homebridge";
      rev = "v" + version;
      sha256 = "sha256-Eau8DR2c+2/Nuop2nmkwHPHEUWvzRzm2fTUxuXhgBmM=";
    };

    # vendor the dependency tree
    npmDepsHash = "sha256-Wvyoyq+myUgyGZkK+90H5YSVStL23SyxIJLWFcamQ7w=";
    dontNpmBuild = true; # skip `npm run build`

    # buildNpmPackage puts the CLI at $out/bin/homebridge automatically
    meta = with lib; {
      description = "Homebridge – HomeKit bridge";
      license = licenses.asl20;
      platforms = platforms.unix;
    };
  }
