# biovalid: lightweight bioinformatics file validator from RIVM. No runtime
# Python deps; pure-python wheel built via hatchling.
{ lib, buildPythonPackage, fetchFromGitHub, hatchling }:

buildPythonPackage rec {
  pname = "biovalid";
  version = "0.3.0";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "RIVM-bioinformatics";
    repo = "biovalid";
    rev = "biovalid-v${version}";
    hash = "sha256-5XLuAgnOkX5LDbpuI06qjAlMS6OXugFNNvB1LYb7AAw=";
  };

  build-system = [ hatchling ];

  pythonImportsCheck = [ "biovalid" ];

  meta = with lib; {
    description = "Quick validation of bioinformatics files";
    homepage = "https://github.com/RIVM-bioinformatics/biovalid";
    license = licenses.agpl3Only;
  };
}
