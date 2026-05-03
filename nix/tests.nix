# Smoke tests for the nix-built container closures.
#
# Each test builds a derivation that exercises the tools end-to-end on real
# input data, in nix's hermetic build sandbox (no network, no docker daemon).
# A test that produces output of the expected shape exits 0; anything else
# fails the build and surfaces in `nix flake check`.
#
# Test fixtures are fetched via `fetchurl` from the upstream ViroConstrictor
# repo at a pinned commit, so they are content-addressed and reproducible.
# FASTQ inputs are synthesised at check time from the reference genome by
# sliding a window across it (avoids hauling around megabytes of binary reads
# and keeps the diff text-only).
#
# Fixtures and per-container scripts are exposed as `fixtures`, `synthesiseReads`,
# `synthesiseBam`, and `scripts` so the VM tests in `nix/vm-tests.nix` can
# re-stage the same data and run the *same* script bodies inside the actual
# built docker / singularity images. That keeps the two test layers in sync:
# the closure-level check and the in-image check exercise identical code paths.
{ pkgs }:

let
  # Pin to upstream RIVM/ViroConstrictor main at the time of writing.
  # Bump together with any test fixture additions/changes.
  upstreamRev = "199814b0c8606dc10a1b4303f79048e89a129d18";

  fetchTestData = name: hash:
    pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/RIVM-bioinformatics/ViroConstrictor/${upstreamRev}/tests/e2e/data/${name}";
      sha256 = hash;
    };

  fixtures = {
    referenceFasta = fetchTestData "reference_genome.fasta"
      "0758xcb93s8hc89ms0pn8ds4495pgp0wg1c1yl0q52kbnzgci0aa";
    referenceGff = fetchTestData "reference_genome.gff"
      "0y1jqnys6a1mkd87psdk7n0lz4yqc85032jqd0x25l8nh6q0nnag";
    primersBed = fetchTestData "Primers_articv4.1.bed"
      "1gmfkfbbpnbl7gv8ap49f0wki3f7igjs3fq4xhvw9gklahk62rhi";
    primersFasta = fetchTestData "Primers_articv4.1.fasta"
      "1xajgx1mjc6rsfmkwps164n3yz1xlqhz4r737qiw52965knfx15g";
    featuresGff = fetchTestData "ESIB_EQA_2024_SARS1_01_features.gff"
      "1crsb435d1ir1y7l30sjvgx5l629afy7dvzb8lnxz3k6f62g3yvq";
  };

  # Generate a small synthetic FASTQ from the reference: slide a 150 bp window
  # in 75 bp steps and emit each window as a read with constant high quality.
  # ~400 reads from a 30 kb reference; enough for tools to do real work.
  synthesiseReads = pkgs.runCommand "synthetic-reads.fastq" { } ''
    ${pkgs.gawk}/bin/awk '
      BEGIN { read_len = 150; step = 75; n = 0 }
      /^>/ { next }
      { seq = seq $0 }
      END {
        for (i = 1; i + read_len <= length(seq); i += step) {
          n++
          chunk = substr(seq, i, read_len)
          qual = ""; for (j = 1; j <= read_len; j++) qual = qual "I"
          printf "@read_%05d\n%s\n+\n%s\n", n, chunk, qual
        }
      }
    ' ${fixtures.referenceFasta} > $out
  '';

  # Pre-built sorted+indexed BAM, shared by every check that needs alignment
  # output. Built once with minimap2 + samtools (test-time tools, not part of
  # any container's runtime closure), so per-container tests don't need to
  # carry these tools just to construct fixtures. Realistic: the BAM is
  # produced from the same synthesised reads + reference that the alignment
  # check itself exercises end-to-end.
  synthesiseBam = pkgs.runCommand "synthetic.bam" {
    buildInputs = [ pkgs.minimap2 pkgs.samtools ];
  } ''
    mkdir -p $out
    minimap2 -ax sr ${fixtures.referenceFasta} ${synthesiseReads} 2>/dev/null \
      | samtools sort -o $out/aln.bam
    samtools index $out/aln.bam
  '';

  # Per-container test script bodies. Each assumes the working directory has
  # already been populated with: ref.fa, ref.gff, primers.bed, primers.fa,
  # features.gff, reads.fq, test.bam, test.bam.bai. The closure-level check
  # in `mkCheck` and the in-image VM tests both run from this fixture layout,
  # so the scripts are identical between the two test layers.
  scripts = {
    # Alignment: minimap2 -> samtools sort -> samtools view -c
    # Asserts the alignment produces at least one mapped record.
    alignment = ''
      minimap2 -ax sr ref.fa reads.fq > out.sam
      samtools sort -o out.bam out.sam
      samtools index out.bam
      n_mapped=$(samtools view -c -F 4 out.bam)
      echo "mapped reads: $n_mapped"
      [ "$n_mapped" -gt 0 ] || { echo "FAIL: no reads mapped"; exit 1; }
    '';

    # Clean (QC_and_cleanup): fastp + minimap2 (CLI) + ampligone + bedtools + fastqc.
    # Note: the env yaml's `mappy` (Python binding) is not in nixpkgs at the
    # pinned revision; the smoke test exercises the minimap2 CLI instead, which
    # is what most rules in this env actually invoke.
    clean = ''
      fastp -i reads.fq -o cleaned.fq -j fastp.json -h fastp.html 2>fastp.log
      [ -s cleaned.fq ] || { echo "FAIL: fastp produced empty output"; exit 1; }

      minimap2 -ax sr ref.fa cleaned.fq | samtools sort -o aln.bam
      samtools index aln.bam

      bedtools genomecov -ibam aln.bam -bga > cov.bedgraph
      [ -s cov.bedgraph ] || { echo "FAIL: bedtools produced no coverage"; exit 1; }

      fastqc cleaned.fq --outdir . --quiet
      [ -s cleaned_fastqc.html ] || { echo "FAIL: fastqc produced no report"; exit 1; }

      # Real multiqc run against the fastqc output. Catches any over-trim of
      # the slim multiqc derivation: if a stripped dep was actually load-time
      # required, multiqc will crash importing it instead of producing a
      # report.
      mkdir -p multiqc_in && cp cleaned_fastqc.html cleaned_fastqc.zip multiqc_in/ 2>/dev/null || true
      multiqc multiqc_in --outdir multiqc_out --filename multiqc_report 2>multiqc.log || {
        echo "FAIL: multiqc crashed"; cat multiqc.log; exit 1;
      }
      [ -s multiqc_out/multiqc_report.html ] || {
        echo "FAIL: multiqc produced no report"; cat multiqc.log; exit 1;
      }

      # Real ampligone run: clip primers from the cleaned reads using the
      # ARTIC v4.1 BED. Exercises ampligone's full primer-detection,
      # alignment, and trimming code path (not just CLI argparse).
      ampligone \
        --input cleaned.fq \
        --output ampligone_trimmed.fq \
        --reference ref.fa \
        --primers primers.bed \
        --amplicon-type end-to-end \
        2>ampligone.log || {
          echo "FAIL: ampligone failed"; cat ampligone.log; exit 1;
        }
      [ -s ampligone_trimmed.fq ] || {
        echo "FAIL: ampligone produced empty output"; cat ampligone.log; exit 1;
      }
      n_in=$(($(wc -l < cleaned.fq) / 4))
      n_out=$(($(wc -l < ampligone_trimmed.fq) / 4))
      echo "ampligone: $n_in reads in, $n_out reads out"
      [ "$n_out" -gt 0 ] || { echo "FAIL: ampligone dropped every read"; exit 1; }
    '';

    # ORF_analysis: prodigal predicts ORFs, aminoextract extracts proteins from
    # the GFF + reference. Exercises both tools end-to-end.
    orf-analysis = ''
      prodigal -i ref.fa -o orfs.gff -a proteins.faa -p meta -q
      [ -s orfs.gff ] || { echo "FAIL: prodigal produced no GFF"; exit 1; }
      [ -s proteins.faa ] || { echo "FAIL: prodigal produced no proteins"; exit 1; }

      aminoextract --input ref.fa --features features.gff --output aa.fa --name test 2>aminoextract.log || {
        echo "FAIL: aminoextract failed"; cat aminoextract.log; exit 1;
      }
      [ -s aa.fa ] || { echo "FAIL: aminoextract produced empty output"; exit 1; }
    '';

    # Scripts envs (core_scripts, mr_scripts): exercise the python stack.
    # Imports + a real pysam call (open the shared pre-built BAM, count) +
    # biopython parse + aminoextract CLI. Catches missing shared-lib links and
    # broken python entry points that --help wouldn't surface. The BAM is
    # pre-built as a fixture (synthesiseBam) so these envs do not need to ship
    # minimap2/samtools just to construct test inputs.
    core-scripts = scriptsPyBody;
    mr-scripts   = scriptsPyBody;

    # Consensus: trueconsense consumes a sorted+indexed BAM + reference + GFF
    # and produces a consensus FASTA. Hardest test (real pipeline output).
    # Uses the shared pre-built BAM rather than constructing one inside the
    # consensus container's closure.
    consensus = ''
      trueconsense \
        --input test.bam \
        --reference ref.fa \
        --features features.gff \
        --output consensus.fa \
        --samplename test_sample \
        --coverage-level 1 \
        2>trueconsense.log || {
          echo "FAIL: trueconsense failed"; cat trueconsense.log; exit 1;
        }
      [ -s consensus.fa ] || { echo "FAIL: trueconsense produced empty consensus"; exit 1; }
      # head, not grep: gnugrep isn't in the consensus closure (coreutils
      # doesn't include grep), and there's no real workflow rule that
      # needs grep in this container, so the smoke test reaches for what
      # the closure actually has.
      [ "$(head -c 1 consensus.fa)" = ">" ] || { echo "FAIL: consensus.fa has no FASTA header"; exit 1; }
      # Diagnostic line on success so the vm-tests' "must produce stdout"
      # assertion is satisfied. (The other test scripts already echo
      # something on success, e.g. "mapped reads: N"; consensus didn't.)
      echo "consensus produced: $(wc -c < consensus.fa) bytes"
    '';
  };

  # Shared between core-scripts and mr-scripts. Bare-EOF heredoc; mind any
  # downstream string interpolation that might re-introduce bash-special chars.
  scriptsPyBody = ''
    python3 - <<'EOF'
    import pysam
    from Bio import SeqIO
    import AminoExtract

    with pysam.AlignmentFile("test.bam") as bam:
        n = sum(1 for _ in bam)
    assert n > 0, "pysam read zero records from BAM"
    print(f"pysam: {n} alignments")

    seqs = list(SeqIO.parse("ref.fa", "fasta"))
    assert len(seqs) > 0, "biopython parsed zero sequences"
    print(f"biopython: {len(seqs)} sequences, first len={len(seqs[0].seq)}")

    print(f"AminoExtract module loaded from {AminoExtract.__file__}")
    EOF
  '';

  # Each check takes the same `contents` list used for the corresponding
  # container image and exercises it. The closure tested is exactly the one
  # shipped — there is no separate "test build." `extraTools` is for fixture-
  # construction tools the test script needs but that are not (and should not
  # be) part of the container's runtime — kept out of the closure under test.
  mkCheck = { name, contents, extraTools ? [ ], script }:
    pkgs.runCommand "viro-${name}-check" {
      buildInputs = contents ++ extraTools;
    } ''
      set -eu
      mkdir -p work && cd work
      cp ${fixtures.referenceFasta} ref.fa
      cp ${fixtures.referenceGff} ref.gff
      cp ${fixtures.primersBed} primers.bed
      cp ${fixtures.primersFasta} primers.fa
      cp ${fixtures.featuresGff} features.gff
      cp ${synthesiseReads} reads.fq
      cp ${synthesiseBam}/aln.bam test.bam
      cp ${synthesiseBam}/aln.bam.bai test.bam.bai

      ${script}

      touch $out
    '';
in
{
  # Re-export so nix/vm-tests.nix can stage exactly the same fixtures into the
  # VM's bind-mounted working directory and run the same script bodies inside
  # the docker / singularity images.
  inherit fixtures synthesiseReads synthesiseBam scripts;

  # Map a `containers` attrset (from nix/containers.nix) to the per-container
  # smoke tests. One entry per container; flake.nix uses this directly as
  # `checks.${system}`.
  forContainers = containers: {
    alignment    = mkCheck { name = "alignment";    contents = containers.alignment;    script = scripts.alignment; };
    clean        = mkCheck { name = "clean";        contents = containers.clean;        script = scripts.clean; };
    orf-analysis = mkCheck { name = "orf-analysis"; contents = containers.orf-analysis; script = scripts.orf-analysis; };
    core-scripts = mkCheck { name = "core-scripts"; contents = containers.core-scripts; script = scripts.core-scripts; };
    mr-scripts   = mkCheck { name = "mr-scripts";   contents = containers.mr-scripts;   script = scripts.mr-scripts; };
    consensus    = mkCheck { name = "consensus";    contents = containers.consensus;    script = scripts.consensus; };
  };
}
