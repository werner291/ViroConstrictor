# Multi-node SLURM VM check: takes the same Nix-built ViroConstrictor +
# .sif container cache used by `vm-pipeline-e2e`, but distributes the
# pipeline across a real SLURM cluster (controller + N workers + submit
# host) booted in QEMU. Exercises the SLURM scheduling code path that
# ViroConstrictor's `_assign_resources_slurm` (workflow_config.py:359)
# carries with the maintainer-confessed
# "we don't have a SLURM cluster to properly test this on" TODO.
#
# Topology (mirrors the upstream nixpkgs nixos/tests/slurm.nix shape, minus
# slurmdbd + slurmrestd, which we don't need for the dispatch path):
#
#   submit  ──┐ runs `viroconstrictor --scheduler SLURM`, exports /work via NFS
#   control ──┤ slurmctld
#   node1   ──┤ slurmd
#   node2   ──┘ slurmd
#
# The pipeline workdir, container .sif cache, input fastq, and snakemake
# state all live under /work, NFS-shared from submit to every node, so
# rules dispatched via sbatch onto node1/node2 see the same paths the
# orchestrator sees.
#
# Wired into flake.nix as `packages.x86_64-linux.vm-pipeline-slurm`, NOT
# under `checks`: same rationale as the existing pipeline-e2e — multi-VM
# tests with real bioinformatics rules are too slow / too non-hermetic
# to gate `nix flake check`.
{ pkgs, images, containers, viroconstrictor }:

let
  # Python interpreter on PATH that has viroconstrictor + the SLURM
  # executor plugin importable. snakemake's slurm-jobstep executor on
  # the worker spawns its own `python -m snakemake` subprocess; that
  # process needs the plugin on sys.path, so it has to live in the
  # withPackages env, not just be available as a separate derivation.
  vcPython = pkgs.python3.withPackages (ps: [
    ps.viroconstrictor
    ps.snakemake-executor-plugin-slurm
    ps.snakemake-executor-plugin-slurm-jobstep
  ]);

  # Same recipe-hash pinning + .sif staging as vm-test-pipeline-e2e.nix.
  # Kept as a copy here rather than refactored into a shared helper to
  # keep the prototype self-contained while we're still iterating.
  recipeHashes = {
    "alignment"    = "05de3b";
    "clean"        = "c5ce21";
    "consensus"    = "56c7b4";
    "core_scripts" = "0362c0";
    "mr_scripts"   = "3eafb1";
    "orf_analysis" = "e0817a";
  };
  nixNameToRecipe = {
    "alignment"    = "alignment";
    "clean"        = "clean";
    "consensus"    = "consensus";
    "core-scripts" = "core_scripts";
    "mr-scripts"   = "mr_scripts";
    "orf-analysis" = "orf_analysis";
  };
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

  realReads = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/nf-core/test-datasets/viralrecon/illumina/amplicon/sample1_R1.fastq.gz";
    sha256 = "0cdhabikxp4miyg5lnvyy6xz96mh6109i654nvmcsz8nwd896imp";
  };

  # ViroConstrictor settings: HPC mode + SLURM scheduler. queuename = the
  # partition we configure below in slurmConfig (`debug` is the upstream
  # convention). repro_method = containers so it picks up the .sif cache
  # rather than trying to spin conda envs inside the workers.
  settingsIni = pkgs.writeText "viroconstrictor-slurm-settings.ini" ''
    [COMPUTING]
    compmode = grid
    queuename = debug
    scheduler = SLURM

    [GENERAL]
    auto_update = no
    ask_for_update = no

    [REPRODUCTION]
    repro_method = containers
    container_cache_path = /work/sifs
  '';

  # Shared SLURM config block, imported into every node. Mirrors upstream
  # nixos/tests/slurm.nix, simplified: no slurmdbd, no JWT, no MPI.
  # `controlMachine = "control"` lets every other node find slurmctld.
  # 2 CPUs per worker is enough for snakemake to schedule rules in
  # parallel across both nodes; `MaxTime=INFINITE` keeps tiny jobs from
  # being killed for time-limit reasons.
  slurmConfig = {
    services.slurm = {
      controlMachine = "control";
      nodeName = [ "node[1-2] CPUs=2 State=UNKNOWN" ];
      partitionName = [ "debug Nodes=node[1-2] Default=YES MaxTime=INFINITE State=UP" ];
    };
    networking.firewall.enable = false;
    # Munge auth: the upstream test hand-rolls a tmpfiles entry rather
    # than going through the services.munge module so the same bytes
    # land on every node verbatim. Matches that pattern.
    systemd.tmpfiles.rules = [
      "f /etc/munge/munge.key 0400 munge munge - vm-test-slurm-shared-munge-key-not-for-real-use"
    ];
  };

  # Configuration shared by every node that runs ViroConstrictor rules
  # (submit as orchestrator, workers as executors). Same apptainer +
  # vcPython closure on each. /work is reached differently per role:
  # submit owns it as a local directory and re-exports via NFS, workers
  # mount it from submit. This is the same shared-storage pattern any
  # real SLURM cluster uses (NFS / Lustre / GPFS / BeeGFS); the
  # nixosTest framework would let us cheat with virtio-9p (`/tmp/shared`
  # is already passed through to every VM), but NFS is the production
  # case and we want CI fidelity, not just a passing dispatch test.
  pipelineCommon = { pkgs, ... }: {
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
      pkgs.ncurses
      viroconstrictor
      vcPython
    ];
  };

  # Worker-side: nfs client utilities + an empty /work directory. We
  # mount NFSv3 manually from the test script (rather than via
  # fileSystems / automount) so failures surface as clear `mount`
  # error messages instead of a silent automount timeout.
  workerWorkMount = {
    boot.supportedFilesystems = [ "nfs" ];
    services.rpcbind.enable = true;
    systemd.tmpfiles.rules = [ "d /work 0777 root root -" ];
    environment.systemPackages = [ pkgs.nfs-utils pkgs.iputils ];
  };
in
pkgs.testers.nixosTest {
  name = "viro-vm-pipeline-slurm";

  nodes = {
    control = { ... }: {
      imports = [ slurmConfig ];
      services.slurm.server.enable = true;
      # Need slurm-tools on the controller so the test driver can call
      # sinfo/sacct from it for the proof-of-submission assertions.
      services.slurm.client.enable = true;
    };

    node1 = { ... }: {
      imports = [ slurmConfig (pipelineCommon { inherit pkgs; }) workerWorkMount ];
      services.slurm.client.enable = true;
      virtualisation = {
        diskSize = 8192;
        memorySize = 4096;
        cores = 2;
      };
    };

    node2 = { ... }: {
      imports = [ slurmConfig (pipelineCommon { inherit pkgs; }) workerWorkMount ];
      services.slurm.client.enable = true;
      virtualisation = {
        diskSize = 8192;
        memorySize = 4096;
        cores = 2;
      };
    };

    submit = { ... }: {
      imports = [ slurmConfig (pipelineCommon { inherit pkgs; }) ];
      services.slurm.enableStools = true;
      virtualisation = {
        diskSize = 16384;
        memorySize = 6144;
        cores = 4;
      };
      # /work is a real local directory on submit. Re-exported via NFSv3
      # with no_root_squash so root-owned writes from the test driver
      # land cleanly. insecure allows requests from non-privileged source
      # ports, which the worker mount unit may use; cheaper than fighting
      # `noresvport` plumbing.
      systemd.tmpfiles.rules = [
        "d /work 0777 root root -"
      ];
      services.nfs.server = {
        enable = true;
        exports = ''
          /work *(rw,sync,no_root_squash,no_subtree_check,insecure)
        '';
      };
    };
  };

  testScript = ''
    start_all()

    with subtest("cluster_comes_up"):
        control.wait_for_unit("multi-user.target")
        control.wait_for_unit("slurmctld.service")
        control.wait_for_open_port(6817)
        for n in [node1, node2, submit]:
            n.wait_for_unit("multi-user.target")
        for n in [node1, node2]:
            n.wait_for_unit("slurmd.service")
            n.wait_for_open_port(6818)
        control.wait_until_succeeds(
            "sinfo -Nh -o '%N %T' | grep -Fx 'node1 idle' && "
            "sinfo -Nh -o '%N %T' | grep -Fx 'node2 idle'"
        )

    with subtest("nfs_handshake"):
        # NFS server up on submit, exports advertised to workers, then
        # mount /work over NFSv3 from each worker and confirm a write
        # on submit reads back through the mount.
        submit.wait_for_unit("nfs-server.service")
        submit.succeed("exportfs -v | grep -F /work")
        submit.succeed("echo hello-from-submit > /work/.handshake")

        for n in [node1, node2]:
            # Pre-flight: hostname resolution + RPC reachability. If
            # either fails, the mount will hang; surface it now.
            n.succeed("getent hosts submit")
            n.succeed("ping -c1 -W2 submit")
            n.succeed("rpcinfo -p submit | grep -F nfs")
            n.succeed(
                "mount -t nfs -o nfsvers=3,rw,soft,timeo=50 "
                "submit:/work /work"
            )
            n.succeed("grep -Fx hello-from-submit /work/.handshake")
            n.log("[mount] " + n.succeed("findmnt /work"))

        submit.succeed("rm /work/.handshake")

    with subtest("stage_pipeline_inputs"):
        submit.succeed("mkdir -p /work/sifs /work/input /work/output")
        submit.succeed("cp -rL ${containerCache}/. /work/sifs/")
        submit.succeed("cp ${../tests/e2e/data/reference_genome.fasta} /work/reference.fasta")
        submit.succeed("cp ${../tests/e2e/data/ESIB_EQA_2024_SARS1_01_features.gff} /work/features.gff")
        submit.succeed("cp ${../tests/e2e/data/Primers_articv4.1.bed} /work/primers.bed")
        submit.succeed("cp ${realReads} /work/input/sample1_R1.fastq.gz")
        submit.succeed("cp ${settingsIni} /work/settings.ini")
        submit.succeed("cp ${settingsIni} /root/.ViroConstrictor_defaultprofile.ini")

    with subtest("run_pipeline_via_slurm"):
        # Same invocation shape as vm-test-pipeline-e2e.nix: bypass the
        # `viroconstrictor` wrapper and call vcPython's python directly,
        # so sys.executable points at an interpreter that has snakemake
        # + the slurm executor plugin importable. ViroConstrictor's
        # scheduler resolution will see scheduler=SLURM in
        # /root/.ViroConstrictor_defaultprofile.ini and route through
        # `_assign_resources_slurm` + the snakemake slurm executor.
        #
        # `--threads 4` is the orchestrator's local thread budget for the
        # snakemake driver; per-rule thread counts are independent and
        # come from the workflow's resources.
        rc, _ = submit.execute(
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
        submit.log(f"[viroconstrictor] exit code: {rc}")
        log_tail = submit.succeed("tail -300 /work/viroconstrictor.log || true")
        submit.log("[viroconstrictor log tail]\n" + log_tail)
        # Capture the SLURM accounting record from the controller as
        # proof the dispatch path actually fired sbatch jobs.
        sacct = control.succeed(
            "sacct -X -P -n -o JobID,JobName,State,Partition,NodeList | head -50 || true"
        )
        control.log("[sacct]\n" + sacct)
        assert rc == 0, f"viroconstrictor exited {rc}; see logs above"

    with subtest("real_jobs_landed_on_workers"):
        # The product test is two-part: pipeline exited 0, AND the SLURM
        # accounting database shows at least one COMPLETED job that
        # actually ran on a compute node (not just the submit host).
        # If the pipeline exited 0 but no jobs hit node1/node2, we'd be
        # silently testing the local-execution path, which is not the
        # claim of this VM check.
        rows = control.succeed(
            "sacct -X -P -n -o State,NodeList | grep -E '^(COMPLETED|RUNNING)\\|node[12]' | wc -l"
        ).strip()
        assert int(rows) > 0, (
            "no SLURM jobs accounted to node1/node2; "
            "pipeline ran but didn't dispatch via the cluster"
        )

        # And the same data-flow sanity check the local e2e uses: real
        # FASTA output proves rules actually executed, not just got
        # queued.
        n_fasta = submit.succeed(
            "find /work/output -name '*.fasta' -not -empty 2>/dev/null | wc -l"
        ).strip()
        assert int(n_fasta) > 0, "no non-empty FASTA output; pipeline produced no data"
  '';
}
