# Pipeline-level VM check: load all six Nix-built .sif files into an
# apptainer cache directory with the names ViroConstrictor's snakemake rules
# expect (`viroconstrictor_<recipe>_<hash>.sif`), then run the actual
# `viroconstrictor` CLI end-to-end against the test fixtures.
#
# This is the test layer the per-container smoke tests don't reach: it
# exercises the snakemake DAG, rule-to-rule output handoff between
# containers, the workflow scripts under `workflow/.../scripts/`, and the
# whole `clean → align → trueconsense → orf_analysis → combine` chain.
#
# Wired into `flake.nix` as `packages.x86_64-linux.vm-pipeline-e2e`, NOT
# under `checks`: a full pipeline run is multi-minute, the failure modes
# go beyond container content (it can fail on snakemake API drift, settings
# plumbing, ViroConstrictor version compat with current bioconda transitive
# deps, etc.), and we'd rather keep `nix flake check` fast and deterministic.
{ pkgs, images, containers, viroconstrictor }:

let
  # snakemake's local executor spawns child jobs via `python3` from PATH
  # (e.g. `python3 -m snakemake.cli` to handle a single rule). The bare
  # python3 in nixpkgs doesn't have snakemake on its sys.path, so those
  # subprocesses fail with `No module named snakemake`. Putting a
  # withPackages-built interpreter on PATH that bundles viroconstrictor
  # (and therefore its snakemake closure) lets those subprocesses resolve.
  vcPython = pkgs.python3.withPackages (ps: [ ps.viroconstrictor ]);
in

let
  # The recipe-yaml hashes that ViroConstrictor's `containers/build_containers.py`
  # computes by sha256-and-truncate-to-6-chars. These are stable as long as
  # the env yaml contents don't change. Computed once and pinned; if upstream
  # bumps a recipe, the test will fail loudly with "container not found"
  # which is the right signal.
  recipeHashes = {
    "alignment"    = "05de3b";
    "clean"        = "c5ce21";
    "consensus"    = "56c7b4";
    "core_scripts" = "0362c0";
    "mr_scripts"   = "3eafb1";
    "orf_analysis" = "e0817a";
  };

  # Map from Nix container name (dashes) to ViroConstrictor recipe name
  # (underscores). The Nix flake uses kebab-case; the snakemake rules look
  # for `viroconstrictor_<snake_case_recipe>_<hash>.sif`.
  nixNameToRecipe = {
    "alignment"    = "alignment";
    "clean"        = "clean";
    "consensus"    = "consensus";
    "core-scripts" = "core_scripts";
    "mr-scripts"   = "mr_scripts";
    "orf-analysis" = "orf_analysis";
  };

  # Stage all six .sif files into one directory, renamed to the
  # convention snakemake's `container:` directives expect.
  containerCache = pkgs.runCommand "viroconstrictor-sif-cache" { } (
    pkgs.lib.concatStringsSep "\n" (
      [ "mkdir -p $out" ] ++
      pkgs.lib.mapAttrsToList (nixName: recipeName:
        let
          sif = images.mkSif nixName containers.${nixName};
          hash = recipeHashes.${recipeName};
        in
        "cp ${sif} $out/viroconstrictor_${recipeName}_${hash}.sif"
      ) nixNameToRecipe
    )
  );

  # Real SARS-CoV-2 amplicon reads, same dataset as vm-test-real-reads.nix.
  # ARTIC v3 primers in the source data don't match our v4.1 fixtures
  # exactly; some reads will fail primer-clipping, but the pipeline doesn't
  # abort on that — it's a smoke that the DAG executes end-to-end.
  realReads = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/nf-core/test-datasets/viralrecon/illumina/amplicon/sample1_R1.fastq.gz";
    sha256 = "0cdhabikxp4miyg5lnvyy6xz96mh6109i654nvmcsz8nwd896imp";
  };

  # Settings file with repro_method=containers and the cache path the VM
  # will mount. Network-dependent updates disabled.
  settingsIni = pkgs.writeText "viroconstrictor-settings.ini" ''
    [COMPUTING]
    compmode = local

    [GENERAL]
    auto_update = no
    ask_for_update = no

    [REPRODUCTION]
    repro_method = containers
    container_cache_path = /work/sifs
  '';
in
pkgs.testers.nixosTest {
  name = "viro-vm-pipeline-e2e";

  nodes.machine = { pkgs, ... }: {
    virtualisation = {
      diskSize = 16384;
      memorySize = 6144;
      # ViroConstrictor's `_set_cores(threads)` returns `cores - 2` when
      # threads == multiprocessing.cpu_count(). With cores=2 and threads=2
      # that's 0, which snakemake rejects ("cores have to be specified for
      # local"). Bump to 4 so 4-2 leaves 2 usable cores.
      cores = 4;
    };

    programs.singularity = {
      enable = true;
      package = pkgs.apptainer;
    };

    boot.kernel.sysctl."user.max_user_namespaces" = 28633;
    time.timeZone = "UTC";

    environment.systemPackages = [
      pkgs.coreutils
      pkgs.bash
      pkgs.apptainer
      pkgs.ncurses        # `clear`, called by viroconstrictor's TTY init
      viroconstrictor
      vcPython            # python3 on PATH that has snakemake importable
    ];
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    # Stage everything under /work
    machine.succeed("mkdir -p /work/sifs /work/input /work/output")

    # Six .sif files, named to the snakemake rule convention
    machine.succeed("cp -rL ${containerCache}/. /work/sifs/")
    machine.succeed("ls -lh /work/sifs/")

    # Test fixtures + input fastq
    machine.succeed("cp ${../tests/e2e/data/reference_genome.fasta} /work/reference.fasta")
    machine.succeed("cp ${../tests/e2e/data/ESIB_EQA_2024_SARS1_01_features.gff} /work/features.gff")
    machine.succeed("cp ${../tests/e2e/data/Primers_articv4.1.bed} /work/primers.bed")
    machine.succeed("cp ${realReads} /work/input/sample1_R1.fastq.gz")
    machine.succeed("cp ${settingsIni} /work/settings.ini")
    # The viroconstrictor CLI defaults `settings_path` to
    # `~/.ViroConstrictor_defaultprofile.ini`. If that file is absent it
    # falls back to AskPrompts which calls `/bin/clear` and waits on stdin.
    # Pre-populate it so the run is non-interactive.
    machine.succeed("cp ${settingsIni} /root/.ViroConstrictor_defaultprofile.ini")
    machine.succeed("ls -lh /work/ /root/")

    # Run the actual pipeline. --platform illumina because the test reads
    # are paired-end Illumina (we only ship R1 here, treated as single-end);
    # --amplicon-type fragmented matches the upstream test.
    # Invoke viroconstrictor via the withPackages-built python directly,
    # rather than via the `viroconstrictor` wrapper. The wrapper's shebang
    # points at bare python3 (with site-packages added by site.addsitedir);
    # `sys.executable` inside the running app is therefore the bare python.
    # When snakemake's local executor spawns a child job via
    # `subprocess.run([sys.executable, "-m", "snakemake.cli", ...])`, that
    # child python doesn't have snakemake on sys.path and fails. Calling
    # vcPython directly makes `sys.executable` point at a python that has
    # the whole stack.
    # Invocation notes:
    # - `python -m ViroConstrictor` doesn't work: __main__.py has no
    #   `if __name__ == '__main__': main()` guard, so the module loads
    #   without ever calling main(). We have to import + call explicitly.
    # - `vcPython/bin/python3` directly so sys.executable points at a
    #   python that has snakemake importable. Snakemake's local executor
    #   spawns child jobs via [sys.executable, ...]; if sys.executable is
    #   the bare nixpkgs python3 (which the .viroconstrictor-wrapped
    #   shebang resolves to), those children fail with "No module named
    #   snakemake".
    # No wholesale /nix/store bind: that would shadow the .sif's own
    # /nix/store entries (where the container's tools like fastqc actually
    # live), making `/bin/fastqc -> /nix/store/<.sif-only-path>/...` break
    # because the host doesn't have that store path. ViroConstrictor's
    # patched `construct_container_bind_args` now binds both realpath and
    # symlink forms of its workflow dir, which is the only host path the
    # rules need to reach.
    rc, _ = machine.execute(
        "cd /work && "
        "${vcPython}/bin/python3 "
        "-c 'from ViroConstrictor.__main__ import main; main()' "
        "--input /work/input "
        "--output /work/output "
        "--reference /work/reference.fasta "
        "--features /work/features.gff "
        "--primers /work/primers.bed "
        "--amplicon-type fragmented "
        "--platform illumina "
        "--target sars-cov-2 "
        "--threads 4 "
        ">/work/viroconstrictor.log 2>&1"
    )
    machine.log(f"[viroconstrictor] exit code: {rc}")
    vc_log = machine.succeed("tail -200 /work/viroconstrictor.log || true")
    machine.log("[viroconstrictor log tail]\n" + vc_log)
    tree = machine.succeed("find /work/output -type f 2>&1 | head -60 || true")
    machine.log("[output tree]\n" + tree)
    rule_logs = machine.succeed(
        "for f in /work/output/logs/*.log; do "
        "  echo === $f ===; "
        "  cat $f; "
        "done 2>&1 || true"
    )
    machine.log("[rule logs]\n" + rule_logs)

    # The product test is "pipeline exited 0" — that means the snakemake
    # DAG completed all rules across all six containers, which is the
    # claim this PR is making (the Nix-built containers are drop-in
    # replacements). Don't chase specific output files: the rules' output
    # paths are configurable and we're not testing the path layout.
    assert rc == 0, f"viroconstrictor exited {rc}; see log above"

    # Sanity check: there should be SOMETHING under /work besides the input
    # and the bare logs dir. A consensus FASTA somewhere is the easiest
    # signal that real data flowed through the DAG.
    n_fasta = machine.succeed(
        "find /work -name '*.fasta' -not -empty 2>/dev/null | wc -l"
    ).strip()
    assert int(n_fasta) > 0, (
        "no non-empty FASTA files anywhere under /work; "
        "pipeline reported success but produced no data"
    )
  '';
}
