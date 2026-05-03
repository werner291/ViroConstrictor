# ViroConstrictor as a Nix-built Python package, used by the e2e flake app
# (`nix run .#viroconstrictor-e2e`) to drive a real pipeline run against the
# Nix-built .sif containers.
#
# Source comes from the local working tree (the same checkout the flake itself
# lives in). drmaa is left out: the dep is only imported lazily inside
# scheduler.py for HPC-cluster execution, and never reached on `compmode = local`
# runs which is what the e2e exercises.
{ lib
, buildPythonPackage
, hatchling
, urllib3
, biopython
, fpdf2
, pandas
, openpyxl
, pyyaml
, rich
, aminoextract
, biovalid
, bcbio-gff
, numpy
, packaging
, snakemake
}:

buildPythonPackage {
  pname = "ViroConstrictor";
  version = "local";
  pyproject = true;

  # Source = the repo root one level up from this file. The pyproject.toml
  # there packages both `ViroConstrictor/` and `snakemake_logger_plugin_viroconstrictor/`
  # as wheel modules.
  src = lib.cleanSourceWith {
    src = ../.;
    filter = path: type:
      let base = baseNameOf path; in
      base != "result"
        && base != ".direnv"
        && !(lib.hasPrefix "result-" base)
        && !(lib.hasSuffix ".pyc" base);
  };

  build-system = [ hatchling ];

  # Snakemake 9.16.3 (current nixpkgs) refactored the module-level
  # `snakemake.logging.logger_manager` singleton into an instance attribute
  # on `SnakemakeApi`. ViroConstrictor's workflow_executor.py imports the
  # symbol and reaches for it after the SnakemakeApi context exits to
  # forcibly stop the queue listener between sequential workflow runs (e.g.
  # match_ref then main from the same Python process).
  #
  # The newer SnakemakeApi cleans up its own logger_manager on `__exit__`,
  # so the post-context cleanup block is dead code under 9.16+. Stripping
  # the import and the cleanup block lets the package run against current
  # snakemake; the original behaviour (re-init guard between sequential
  # API calls) was already implicit in the new instance lifecycle.
  postPatch = ''
    substituteInPlace ViroConstrictor/workflow_executor.py \
      --replace-fail \
        'from snakemake.logging import logger, logger_manager' \
        'from snakemake.logging import logger'

    # Replace the post-context manual cleanup block: stub out the three
    # logger_manager references (`if logger_manager.queue_listener`,
    # `logger_manager.stop()`, `logger_manager.initialized = False`) with
    # `pass` so the rest of the file structure stays intact.
    substituteInPlace ViroConstrictor/workflow_executor.py \
      --replace-fail \
        'if logger_manager.queue_listener is not None:' \
        'if False:  # patched: logger_manager moved to SnakemakeApi instance in 9.16+' \
      --replace-fail \
        'logger_manager.stop()' \
        'pass  # patched out' \
      --replace-fail \
        'logger_manager.initialized = False' \
        'pass  # patched out'
  '';

  # Upstream pyproject pins exact versions (`==1.85.*`, `==2.8.4`, etc.) that
  # don't match the slightly newer point-releases shipping in nixpkgs. The
  # APIs we exercise haven't broken across these point bumps, so relax
  # rather than carry a stack of pin overrides.
  pythonRelaxDeps = [ "biopython" "fpdf2" "rich" "urllib3" "pandas" "openpyxl" "pyyaml" "AminoExtract" ];

  # drmaa is required by pyproject but only used lazily inside scheduler.py
  # for HPC-cluster execution. The e2e flake app runs `compmode = local`,
  # which never reaches that import. Drop the dep rather than packaging
  # drmaa-python (a thin wrapper around a system DRMAA C lib that doesn't
  # exist on this host) for a code path we don't take.
  pythonRemoveDeps = [ "drmaa" ];

  # Snakemake is missing from pyproject deps but is plainly required at
  # runtime; we add it.
  dependencies = [
    urllib3
    biopython
    fpdf2
    pandas
    openpyxl
    pyyaml
    rich
    aminoextract
    biovalid
    bcbio-gff
    numpy
    packaging
    snakemake
  ];

  pythonImportsCheck = [ "ViroConstrictor" ];

  # Tests in the source tree are end-to-end and need network + apptainer; not
  # appropriate for the package-build sandbox.
  doCheck = false;

  meta = with lib; {
    description = "ViroConstrictor: viral amplicon NGS analysis pipeline";
    homepage = "https://github.com/RIVM-bioinformatics/ViroConstrictor";
    license = licenses.agpl3Only;
  };
}
