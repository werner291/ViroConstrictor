{ lib, python3Packages, fetchFromGitHub, file, ... }:

python3Packages.buildPythonApplication rec {
  pname = "aminoextract";
  version = "0.4.1";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "RIVM-bioinformatics";
    repo = "aminoextract";
    rev = "v${version}";
    hash = "sha256-jwtYTXlJnnA2030CEbfbzYDj2zv35EOSzcgsT2VssVw=";
  };

  build-system = [ python3Packages.hatchling ];

  # Upstream pins rich==13.*; nixpkgs ships rich 14.x. The API surface used
  # (basic console formatting) is stable across these majors, so relax the pin.
  pythonRelaxDeps = [ "rich" ];

  dependencies = with python3Packages; [
    biopython
    pandas
    rich
    python-magic
  ];

  # python-magic loads libmagic via ctypes at runtime; ensure it can find it.
  makeWrapperArgs = [
    "--prefix" "LD_LIBRARY_PATH" ":" "${lib.getLib file}/lib"
  ];

  # Upstream has no test suite wired into pyproject; skip pytest discovery.
  doCheck = false;

  pythonImportsCheck = [ "AminoExtract" ];

  meta = with lib; {
    description = "Extract amino acid sequences from a fasta file based on a GFF";
    homepage = "https://github.com/RIVM-bioinformatics/AminoExtract";
    license = licenses.mit;
    mainProgram = "aminoextract";
  };
}
