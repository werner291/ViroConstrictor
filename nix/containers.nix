# Per-container runtime closures, one entry per ViroConstrictor/workflow/envs/*.yaml.
# Python deps go through `pythonWith` so each container ships one Python with
# everything on `sys.path`. bash + coreutils everywhere for snakemake's shell
# rule invocation.
pkgs:

let
  pythonWith = ps: pkgs.python3.withPackages ps;
  base = with pkgs; [ bashInteractive coreutils ];
in
{
  alignment = with pkgs; [ minimap2 samtools (pythonWith (_: [ ])) ] ++ base;

  # Note: env yaml lists `mappy` (Python binding for minimap2), not in
  # nixpkgs and not needed by any current rule. Inline derivation if a future
  # rule does `import mappy`. openjdk-11 from the yaml is dropped: nixpkgs'
  # fastqc bundles its own JDK and no rule shells out to `java` directly.
  #
  # The `multiqc-slim` reference here resolves to the overlay's default
  # build, which uses nixpkgs' polars (= variant 32). To produce a Clean
  # image pinned to a different per-CPU-baseline variant, build the closure
  # via `mkCleanWithMultiqc` from nix/clean-builder.nix instead.
  clean = with pkgs; [
    fastp minimap2 samtools bedtools fastqc-slim multiqc-slim
    procps ampligone
    (pythonWith (ps: with ps; [ pandas biopython ]))
  ] ++ base;

  orf-analysis = with pkgs; [
    prodigal aminoextract
    (pythonWith (ps: with ps; [ pandas biopython ]))
  ] ++ base;

  core-scripts = with pkgs; [
    fastqc-slim aminoextract
    (pythonWith (ps: with ps; [ pandas biopython pysam ]))
  ] ++ base;

  mr-scripts = with pkgs; [
    aminoextract
    (pythonWith (ps: with ps; [ pandas biopython pysam ]))
  ] ++ base;

  consensus = with pkgs; [
    trueconsense aminoextract
    (pythonWith (ps: with ps; [ pysam ]))
  ] ++ base;
}
