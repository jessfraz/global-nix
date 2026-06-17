{pkgs ? import <nixpkgs> {}}: let
  inherit (pkgs) buildNpmPackage fetchFromGitHub lib;
  nodejs = pkgs.nodejs_22;
  python = pkgs.python311;
in
  buildNpmPackage rec {
    pname = "scrypted";
    version = "0.143.0";
    inherit nodejs;

    srcHash = "sha256-5fFyrphAHSAJYfcw5lg7X7zaLt4SXIHQL/3SEPcStiY=";
    src = fetchFromGitHub {
      owner = "koush";
      repo = "scrypted";
      rev = "v${version}";
      hash = srcHash;
    };
    sourceRoot = "${src.name}/server";

    postPatch = ''
      ${nodejs}/bin/node <<'EOF'
      const fs = require("fs");

      const packageJson = JSON.parse(fs.readFileSync("package.json", "utf8"));
      packageJson.dependencies = packageJson.dependencies || {};
      packageJson.dependencies["node-addon-api"] = "^8.3.1";
      fs.writeFileSync("package.json", JSON.stringify(packageJson, null, 2) + "\n");

      const lock = JSON.parse(fs.readFileSync("package-lock.json", "utf8"));
      lock.packages[""].dependencies = lock.packages[""].dependencies || {};
      lock.packages[""].dependencies["node-addon-api"] = "^8.3.1";
      lock.packages["node_modules/node-addon-api"] = {
        version: "8.3.1",
        resolved: "https://registry.npmjs.org/node-addon-api/-/node-addon-api-8.3.1.tgz",
        integrity: "sha512-lytcDEdxKjGJPTLEfW4mYMigRezMlyJY8W4wxJK8zE533Jlb8L8dRuObJFWg2P+AuOIxoCgKF+2Oq4d4Zd0OUA==",
        license: "MIT",
      };
      fs.writeFileSync("package-lock.json", JSON.stringify(lock, null, 2) + "\n");
      EOF
    '';

    npmDepsHash = "sha256-iUzGidZ8eQ4WtYo7cyUAXV+SIVFpbde62fY7TIBaTaY=";
    npmBuildScript = "build";
    makeCacheWritable = true;

    SKIP_INSTALL = "1";
    SCRYPTED_PYTHON_PATH = "${python}/bin/python${python.pythonVersion}";

    meta = with lib; {
      description = "Scrypted smart home video integration platform";
      homepage = "https://github.com/koush/scrypted";
      license = licenses.isc;
      mainProgram = "scrypted-serve";
      platforms = platforms.unix;
    };
  }
