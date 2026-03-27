{
  lib,
  fetchFromGitHub,
  python3Packages,
}:
python3Packages.buildPythonApplication rec {
  pname = "ramp-cli";
  version = "0.1.2";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "ramp-public";
    repo = "ramp-cli";
    tag = "v${version}";
    hash = "sha256-IE/4QyQf3acBABhNtffmFvL5gKSkAZZ8KBMbtn55dWo=";
  };

  nativeBuildInputs = with python3Packages; [
    hatchling
  ];

  propagatedBuildInputs = with python3Packages; [
    click
    httpx
    jsonref
    tomli-w
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
