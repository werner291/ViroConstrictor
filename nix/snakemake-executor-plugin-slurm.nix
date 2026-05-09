# snakemake-executor-plugin-slurm: lets snakemake submit jobs via sbatch
# instead of running rules locally. Required for the multi-node SLURM VM
# test where ViroConstrictor's settings.ini selects `scheduler = SLURM`;
# without this plugin the snakemake CLI rejects `--executor slurm`.
#
# Pinned to 2.0.0 to match ViroConstrictor's env.yml (the conda recipe
# the maintainers test against). nixpkgs ships none of the SLURM
# executor stack today, so we package it here alongside the jobstep
# helper.
{ lib
, buildPythonPackage
, fetchPypi
, poetry-core
, snakemake-interface-common
, snakemake-interface-executor-plugins
, snakemake-executor-plugin-slurm-jobstep
, pandas
, numpy
, throttler
, pyyaml
}:
buildPythonPackage rec {
  pname = "snakemake_executor_plugin_slurm";
  version = "2.0.0";
  pyproject = true;

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-H1bOAqqNUUzqfH7ym13uZhA7+TsMKxHVGDhK1Yghm4A=";
  };

  build-system = [ poetry-core ];

  dependencies = [
    snakemake-interface-common
    snakemake-interface-executor-plugins
    snakemake-executor-plugin-slurm-jobstep
    pandas
    numpy
    throttler
    # Upstream (2.0.0) forgot to declare pyyaml in pyproject; partitions.py
    # imports yaml unconditionally. Add explicitly so import-check passes.
    pyyaml
  ];

  pythonImportsCheck = [ "snakemake_executor_plugin_slurm" ];
  doCheck = false;

  meta = with lib; {
    description = "Snakemake executor plugin: submit jobs via SLURM sbatch";
    homepage = "https://github.com/snakemake/snakemake-executor-plugin-slurm";
    license = licenses.mit;
  };
}
