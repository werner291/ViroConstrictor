{ lib
, buildPythonPackage
, fetchFromGitHub
, file
, hatchling
, biopython
, pandas
, rich
, python-magic
}:

# buildPythonPackage rather than buildPythonApplication so the AminoExtract
# module is importable from python.withPackages envs (e.g. core-scripts and
# mr-scripts, whose smoke tests do `import AminoExtract`). buildPythonPackage
# still produces the `bin/aminoextract` console script via the entry-points
# in pyproject.toml, so the CLI continues to work the same as before.
#
# Each python dep is a separate function argument (rather than the older
# `python3Packages.<dep>` pattern) because nixpkgs's buildPythonPackage lint
# rejects `python3Packages` references when the package is part of an
# `overrideScope` (which it is, per nix/overlay.nix).
buildPythonPackage rec {
  pname = "aminoextract";
  version = "0.4.1";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "RIVM-bioinformatics";
    repo = "aminoextract";
    rev = "v${version}";
    hash = "sha256-jwtYTXlJnnA2030CEbfbzYDj2zv35EOSzcgsT2VssVw=";
  };

  build-system = [ hatchling ];

  # Upstream pins rich==13.*; nixpkgs ships rich 14.x. The API surface used
  # (basic console formatting) is stable across these majors, so relax the pin.
  pythonRelaxDeps = [ "rich" ];

  dependencies = [
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
