{
  lib,
  fetchFromGitHub,
  python3Packages,
}:
python3Packages.buildPythonApplication rec {
  pname = "ramp-cli";
  version = "0.2.98";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "ramp-public";
    repo = "ramp-cli";
    tag = "v${version}";
    hash = "sha256-zis6MGd/tZdnXFId7lFNS+7NVl9JOjGaSWAyyHUsgCs=";
  };

  nativeBuildInputs = with python3Packages; [
    hatchling
  ];

  propagatedBuildInputs = with python3Packages; [
    click
    httpx
    json5
    jsonref
    questionary
    textual
    tomli-w
    # Ramp requires websockets <17; keep the compatible version local to Ramp.
    (websockets.overridePythonAttrs (_: rec {
      version = "16.1";
      src = fetchFromGitHub {
        owner = "aaugustin";
        repo = "websockets";
        tag = version;
        hash = "sha256-YbiDoL4edb6QGDOBRBJliRhEOs5UvZUgWO9f+ooyBcc=";
      };
    }))
    zstandard
  ];

  doCheck = false;
  pythonImportsCheck = ["ramp_cli"];

  meta = with lib; {
    description = "Ramp Developer CLI";
    homepage = "https://github.com/ramp-public/ramp-cli";
    license = licenses.mit;
    mainProgram = "ramp";
  };
}
