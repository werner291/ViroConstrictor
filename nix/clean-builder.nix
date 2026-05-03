# Build a Clean container closure parameterised by polars variant.
#
# The default `containers.clean` uses the overlay's `multiqc-slim`, which in
# turn uses nixpkgs' default polars (= variant 32). For the per-CPU-baseline
# demo we need to pin a specific polars variant per Clean image. This module
# rebuilds `multiqc-slim` against the variant and assembles the same closure
# `containers.clean` ships, so the only thing that differs across variant
# images is the `_polars_runtime_<variant>` directory.
{ pkgs }:

let
  pythonWith = ps: pkgs.python3.withPackages ps;
  base = with pkgs; [ bashInteractive coreutils ];

  multiqcSlimWith = polars: pkgs.callPackage ./multiqc-slim.nix {
    inherit polars;
  };

  # Use a python3Packages set with the variant polars substituted, so the
  # closure's `pythonWith` ships the same variant on the user-facing
  # interpreter (not just multiqc's wrapped one). Lets the VM check assert
  # `python -c "import polars"` directly. Pandas + biopython unchanged.
  pythonWithVariantPolars = polars:
    let
      ps = pkgs.python3Packages;
    in
    pkgs.python3.withPackages (_: [ ps.pandas ps.biopython polars ]);
in
{
  mkCleanClosure = polars: with pkgs; [
    fastp minimap2 samtools bedtools fastqc-slim
    (multiqcSlimWith polars)
    procps ampligone
    (pythonWithVariantPolars polars)
  ] ++ base;
}
