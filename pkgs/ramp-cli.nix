{
  lib,
  fetchFromGitHub,
  python3Packages,
}:
python3Packages.buildPythonApplication rec {
  pname = "ramp-cli";
  version = "0.2.57";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "ramp-public";
    repo = "ramp-cli";
    tag = "v${version}";
    hash = "sha256-46XCjLJ3rAeKR8VH9n0A3DlcCDlmHzAIkr3RhajnUFw=";
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
