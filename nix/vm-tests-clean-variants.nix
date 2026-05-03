# Per-CPU-baseline VM checks for the Clean container.
#
# One nixosTest per polars variant; each loads the variant's docker image,
# runs the Clean smoke (fastp + minimap2 + samtools + bedtools + fastqc +
# multiqc + real ampligone primer-clipping), then asserts on:
#
#   1. exactly one `_polars_runtime_<variant>` directory in site-packages,
#      none of the other variants present,
#   2. `import polars; DataFrame.sum()` returns a real result (this is the
#      load-bearing test that polars's cpuid dispatch found the kept
#      variant; if the wrong manifest were built, this would either crash
#      with illegal-instruction or fall through to an ImportError),
#   3. multiqc produces a report (it imports polars at module load, so a
#      broken variant would surface here too).
#
# Mirrors the pattern in nix/vm-tests.nix: one VM, three runtime phases
# (docker / apptainer / singularity-CE) inside named subtests. SingularityCE
# kept on x86_64 (unlike the aarch64 file, which drops it for unrelated
# reasons documented there).
{ pkgs, tests, images, cleanVariantClosures }:

let
  inherit (tests) fixtures synthesiseReads synthesiseBam scripts;

  fixtureDir = pkgs.runCommand "viro-vm-clean-variant-fixtures" { } ''
    mkdir -p $out
    cp ${fixtures.referenceFasta}     $out/ref.fa
    cp ${fixtures.referenceGff}       $out/ref.gff
    cp ${fixtures.primersBed}         $out/primers.bed
    cp ${fixtures.primersFasta}       $out/primers.fa
    cp ${fixtures.featuresGff}        $out/features.gff
    cp ${synthesiseReads}             $out/reads.fq
    cp ${synthesiseBam}/aln.bam       $out/test.bam
    cp ${synthesiseBam}/aln.bam.bai   $out/test.bam.bai
  '';

  # Clean smoke + per-variant assertions, run inside the container. The
  # variant-name interpolation is a Nix-side substitution, not a shell
  # variable, so a typo would fail at evaluation rather than runtime.
  variantScript = variant: pkgs.writeText "viro-vm-clean-${variant}-script.sh" ''
    set -euo pipefail
    ${scripts.clean}

    # Per-variant assertions. `python3` here is the same `pythonWith` the
    # closure builds, so site-packages is on sys.path without further setup.
    python3 - <<'PY'
    import os, glob, sys, importlib.util
    site = next(p for p in sys.path if p.endswith("site-packages"))
    runtimes = sorted(
        os.path.basename(p)
        for p in glob.glob(os.path.join(site, "_polars_runtime_*"))
    )
    print("polars runtime dirs in site-packages:", runtimes)
    expected = ["_polars_runtime_${variant}"]
    assert runtimes == expected, (
        f"expected exactly {expected}, got {runtimes}"
    )

    import polars
    df = polars.DataFrame({"a": [1, 2, 3]})
    s = df.sum()
    print("df.sum() =>", s)
    # sum of [1,2,3] is 6; surface it explicitly so the VM log captures it.
    assert s["a"][0] == 6, f"unexpected sum: {s}"
    PY
  '';

  vmModule = { pkgs, ... }: {
    virtualisation = {
      diskSize = 8192;
      memorySize = 4096;
      cores = 2;
      docker.enable = true;
    };

    programs.singularity = {
      enable = true;
      package = pkgs.apptainer;
    };

    boot.kernel.sysctl."user.max_user_namespaces" = 28633;
    time.timeZone = "UTC";

    system.extraDependencies = [ pkgs.singularity ];
    environment.systemPackages = [ pkgs.coreutils pkgs.bash ];
  };

  singularityCE = "${pkgs.singularity}/bin/singularity";

  mkVmTest = variant:
    let
      closure = cleanVariantClosures.${variant};
      imageName = "clean-${variant}";
      script = variantScript variant;
    in
    pkgs.testers.nixosTest {
      name = "viro-vm-clean-${variant}";

      nodes.machine = vmModule;

      testScript = ''
        machine.start()
        machine.wait_for_unit("multi-user.target")
        machine.wait_for_unit("docker.service")

        def stage_work():
            machine.succeed("rm -rf /work && mkdir -p /work")
            machine.succeed("cp -r ${fixtureDir}/. /work/")
            machine.succeed("cp ${script} /work/run.sh")
            machine.succeed("chmod +x /work/run.sh")
            # Same UID-10001 chown as nix/vm-tests.nix: the clean-* images
            # run as appuser (10001) per nix/images.nix's User config;
            # without this, fastp / multiqc / ampligone can't write outputs
            # to the bind-mounted /work and the test fails with "Permission
            # denied" on intermediate files like fastp.log.
            machine.succeed("chown -R 10001:10001 /work")

        stage_work()

        with subtest("docker run for clean-${variant}"):
            machine.succeed("${images.mkDocker imageName closure} | docker load")
            out = machine.succeed(
                "docker run --rm "
                "-v /work:/work -w /work "
                "viro-${imageName}-nix:demo "
                "bash /work/run.sh 2>&1"
            )
            machine.log("[docker/clean-${variant}] " + out)
            assert "_polars_runtime_${variant}" in out, (
                "variant assertion did not run inside container"
            )
            assert "df.sum() =>" in out, "polars df.sum() did not print"

        stage_work()
        with subtest("apptainer exec for clean-${variant}"):
            out = machine.succeed(
                "HOME=/root APPTAINER_TMPDIR=/tmp "
                "apptainer exec "
                "--bind /work:/work --pwd /work "
                "${images.mkSif imageName closure} "
                "bash /work/run.sh 2>&1"
            )
            machine.log("[apptainer/clean-${variant}] " + out)
            assert "_polars_runtime_${variant}" in out

        stage_work()
        with subtest("singularity-ce exec for clean-${variant}"):
            out = machine.succeed(
                "HOME=/root SINGULARITY_TMPDIR=/tmp "
                "${singularityCE} exec "
                "--bind /work:/work --pwd /work "
                "${images.mkSif imageName closure} "
                "bash /work/run.sh 2>&1"
            )
            machine.log("[singularity-ce/clean-${variant}] " + out)
            assert "_polars_runtime_${variant}" in out
      '';
    };
in
{
  # { vm-clean-compat = ...; vm-clean-32 = ...; }
  forVariants = variants:
    pkgs.lib.foldl'
      (acc: v: acc // { "vm-clean-${v}" = mkVmTest v; })
      { }
      variants;
}
