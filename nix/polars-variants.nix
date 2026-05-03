# Per-CPU-baseline polars variants.
#
# Upstream py-polars publishes three runtime sub-packages, each a separate
# maturin-built wheel:
#
#   _polars_runtime_compat  ~ x86-64-v2 baseline
#   _polars_runtime_32      ~ x86-64-v3 / AVX2  (this is the variant nixpkgs builds)
#   _polars_runtime_64      ~ x86-64-v4 / AVX-512
#
# At `import polars`, polars/_plr.py dispatches via cpuid and tries the
# variants in order (compat, 64, 32); the first one that imports cleanly wins.
# Missing variants raise ImportError and are skipped silently. So an image
# with exactly one variant installed works on any host whose CPU implements
# at least that variant's feature flags.
#
# nixpkgs' python3Packages.polars hard-codes the `32` manifest:
#
#   maturinBuildFlags = [ "-m" "py-polars/runtime/polars-runtime-32/Cargo.toml" ];
#
# Override that one flag to point at the matching `polars-runtime-${variant}`
# manifest and the same derivation produces the other variants. Conda would
# need a patched bioconda recipe per variant; in Nix it is one expression
# parameterised by the variant name.
{ pkgs }:

let
  variants = [ "compat" "32" "64" ];

  mkPolarsVariant = variant: pkgs.python3Packages.polars.overrideAttrs (old: {
    maturinBuildFlags = [
      "-m"
      "py-polars/runtime/polars-runtime-${variant}/Cargo.toml"
    ];
  });
in
{
  inherit variants mkPolarsVariant;

  # Per-variant attrset: { compat = <drv>; "32" = <drv>; "64" = <drv>; }
  byVariant = pkgs.lib.genAttrs variants mkPolarsVariant;
}
