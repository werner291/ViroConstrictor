# Optional VM smoke test against real SARS-CoV-2 amplicon reads.
#
# Pulls a tiny (~3 MB) Illumina FASTQ from the nf-core/test-datasets
# viralrecon branch via `fetchurl` with a pinned sha256, drops it into the
# alignment-container VM, and asserts minimap2 + samtools produce a non-empty,
# non-zero-mapped BAM. Treats sample1_R1 as single-end; primer scheme is ARTIC
# v3 (different from the v4.1 fixtures), so this exercises alignment only —
# not primer clipping.
#
# Wired into `flake.nix` as `packages.x86_64-linux.vm-alignment-real-reads`,
# NOT under `checks`: the fetch needs internet on first build, and the goal
# here is "demo that fetchurl-based real-data testing is one derivation away,"
# not gating CI on it.
#
# Run via:
#   nix build .#vm-alignment-real-reads -L
{ pkgs, images, containers }:

let
  realReads = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/nf-core/test-datasets/viralrecon/illumina/amplicon/sample1_R1.fastq.gz";
    sha256 = "0cdhabikxp4miyg5lnvyy6xz96mh6109i654nvmcsz8nwd896imp";
  };

  fixtureDir = pkgs.runCommand "viro-vm-real-reads-fixtures" { } ''
    mkdir -p $out
    cp ${../tests/e2e/data/reference_genome.fasta} $out/ref.fa
    cp ${realReads} $out/reads.fq.gz
  '';

  runScript = pkgs.writeText "viro-vm-real-reads-script.sh" ''
    set -euo pipefail
    # minimap2 reads .gz transparently; no gunzip needed (alignment container
    # doesn't ship one). The Clean container is the one that handles fastq.gz
    # inputs in the actual pipeline; this is just an alignment smoke.
    minimap2 -ax sr ref.fa reads.fq.gz > out.sam
    samtools sort -o out.bam out.sam
    samtools index out.bam

    n_total=$(samtools view -c out.bam)
    n_mapped=$(samtools view -c -F 4 out.bam)
    echo "total alignments: $n_total"
    echo "mapped reads: $n_mapped"
    [ "$n_mapped" -gt 0 ] || { echo "FAIL: no real reads mapped"; exit 1; }
  '';
in
pkgs.testers.nixosTest {
  name = "viro-vm-alignment-real-reads";

  nodes.machine = { pkgs, ... }: {
    virtualisation = {
      diskSize = 4096;
      memorySize = 4096;
      cores = 2;
      docker.enable = true;
    };
    time.timeZone = "UTC";
    environment.systemPackages = [ pkgs.coreutils pkgs.bash ];
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("docker.service")

    machine.succeed("rm -rf /work && mkdir -p /work")
    machine.succeed("cp -r ${fixtureDir}/. /work/")
    machine.succeed("cp ${runScript} /work/run.sh")
    machine.succeed("chmod +x /work/run.sh")
    machine.succeed("chown -R 10001:10001 /work")

    machine.succeed("${images.mkDocker "alignment" containers.alignment} | docker load")
    out = machine.succeed(
        "docker run --rm "
        "-v /work:/work -w /work "
        "viro-alignment-nix:demo "
        "bash /work/run.sh 2>&1"
    )
    machine.log("[real-reads] " + out)
    assert "mapped reads:" in out, "alignment did not run"
  '';
}
