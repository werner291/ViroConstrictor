# multiqc overridden to drop nixpkgs-default cloud / parquet / AI deps.
#
# Why: nixpkgs' multiqc-1.30 declares boto3, botocore, s3transfer, kaleido,
# tiktoken, pyarrow as REQUIRED dependencies even though upstream uses
# them only for opt-in features (AWS Bedrock AI support, static-image
# plot export, parquet output). Together those add ~1.5 GB of closure
# for behaviour the ViroConstrictor workflow does not invoke.
#
# Stripping them is verified by the Clean smoke test running a real
# `multiqc` invocation against fastqc output, an over-aggressive trim
# (we initially tried polars and spectra; both turned out to be
# load-time imports) fails loudly rather than silently shipping a
# broken multiqc.
#
# `polars` is parameterised so callers can pin a specific per-CPU-baseline
# variant (compat / 32 / 64) per nix/polars-variants.nix. Default = the
# nixpkgs polars (variant 32).
{ lib, multiqc, python3Packages, polars ? python3Packages.polars }:

multiqc.overridePythonAttrs (old: {
  # nixpkgs' multiqc uses the new pyproject builder where runtime deps
  # live in `dependencies`, not `propagatedBuildInputs`. Filter that.
  # NOTE: polars (multiqc/plots/plot.py) and spectra
  # (multiqc/utils/mqc_colour.py) are imported at module load and CANNOT
  # be dropped. boto3 / kaleido / tiktoken / pyarrow use try-import or
  # lazy-import patterns and are safe to drop.
  #
  # Replace nixpkgs' default polars with the caller-supplied variant; this
  # is what propagates the per-CPU-baseline selection into the Clean image.
  dependencies = map
    (p: if (p.pname or "") == "polars" then polars else p)
    (lib.filter
      (p: !(builtins.elem (p.pname or "") [
        "boto3" "botocore" "s3transfer" "kaleido" "tiktoken" "pyarrow"
      ]))
      old.dependencies);
  # Strip the same names from pyproject.toml so the install phase
  # doesn't re-resolve them as unmet requirements.
  postPatch = (old.postPatch or "") + ''
    substituteInPlace pyproject.toml \
      --replace-quiet '"boto3",' "" \
      --replace-quiet '"kaleido==0.2.1",' "" \
      --replace-quiet '"kaleido",' "" \
      --replace-quiet '"tiktoken",' "" \
      --replace-quiet '"pyarrow",' ""
  '';
})
