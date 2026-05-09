# snakemake-executor-plugin-slurm-jobstep: helper companion for the SLURM
# executor plugin. The plugin itself depends on it transitively. Pulled
# in for the multi-node SLURM VM test (nix/vm-test-pipeline-slurm.nix);
# nothing in the existing local-execution path uses it.
#
# Pinned to 0.3.0 to satisfy the `>=0.3.0,<0.4.0` constraint from
# snakemake-executor-plugin-slurm 2.0.0 (which is what ViroConstrictor's
# env.yml lists).
{ lib
, buildPythonPackage
, fetchPypi
, poetry-core
, snakemake-interface-common
, snakemake-interface-executor-plugins
}:
buildPythonPackage rec {
  pname = "snakemake_executor_plugin_slurm_jobstep";
  version = "0.3.0";
  pyproject = true;

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-6803S93i1PNW5hrCIc1CRFZt2YDbLeMlB4D0VOUlHEk=";
  };

  build-system = [ poetry-core ];

  dependencies = [
    snakemake-interface-common
    snakemake-interface-executor-plugins
  ];

  pythonImportsCheck = [ "snakemake_executor_plugin_slurm_jobstep" ];
  doCheck = false;

  meta = with lib; {
    description = "Snakemake executor plugin: SLURM jobstep helper";
    homepage = "https://github.com/snakemake/snakemake-executor-plugin-slurm-jobstep";
    license = licenses.mit;
  };
}
