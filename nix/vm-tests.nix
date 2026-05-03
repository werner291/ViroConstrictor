# VM-level integration tests for the nix-built container images.
#
# These complement the closure-level tests in `nix/tests.nix`. The closure
# tests run the package set directly inside nix's build sandbox — fast, but
# they don't catch hazards introduced by the *image* layer: missing rootfs
# bits, broken /nix/store layout under the chosen runtime, lazy `dlopen` of a
# stripped lib, Python lazy-imports that only fire on real input, etc.
#
# Each test boots a NixOS VM under `pkgs.nixosTest`, loads the actual built
# Docker / OCI tarball or the actual `.sif` file, and runs the *same* script
# body the closure-level test runs — but inside the running container, on the
# same fixtures. If a tool runs `--help` fine but crashes on real I/O because
# of a stripped runtime dep, this layer surfaces it.
#
# Coverage: for each of the six containers we produce one VM check that
# exercises THREE runtimes back-to-back inside the same VM:
#
#   1. Docker          — `docker load` + `docker run --rm` against the OCI tarball
#   2. Apptainer       — the Linux Foundation fork (`pkgs.apptainer`)
#   3. SingularityCE   — the Sylabs fork (`pkgs.singularity`)
#
# Both Apptainer and SingularityCE consume the same `.sif` file produced by
# `pkgs.singularity-tools.buildImage`. They forked in 2021 and have drifted
# since: different defaults around user namespaces, fakeroot handling, OCI
# integration, mount/bind semantics, and how setuid is (or isn't) used. Many
# downstream HPC sites run one fork or the other; verifying that the same
# `.sif` runs cleanly under BOTH forks meaningfully extends coverage of the
# "different cluster, different runtime" risk this layer is built to surface.
# This is a deliberate cross-runtime test, not duplication.
#
# Wired into `flake.nix` `checks.<system>` as `vm-<container>` (one combined
# test per container, three subtests inside). One VM per container with three
# exec phases inside is the right shape: VM startup dominates wall time, so
# sharing it across the three runtimes keeps the suite tractable, while the
# named subtests still give per-runtime granularity in failure output.
#
# Requires KVM on the host. nixosTest VMs need `/dev/kvm`; on CI runners that
# means a kvm-enabled executor. There is no path to running these without
# nested virt — that's accepted upstream of this file.
#
# Singularity-in-VM gotchas worth knowing:
#   - Both forks need unprivileged user namespaces (`user.max_user_namespaces`).
#     NixOS test VMs have these on by default; explicit sysctl set as a belt-
#     and-braces measure below.
#   - Both forks want a writable home for their session dir; `HOME=/root` is
#     set on each invocation.
#   - Apptainer and SingularityCE both ship a `singularity` symlink and a
#     `run-singularity` helper. Adding both to `environment.systemPackages`
#     would conflict on those names, so we DO NOT install `pkgs.singularity`
#     system-wide; instead we invoke it by absolute store path (`${pkgs.singularity}/bin/singularity`).
#     `programs.singularity` is enabled with `pkgs.apptainer` so that fork
#     gets the standard NixOS setuid wrappers + bind-mount config; SingularityCE
#     runs in unprivileged-userns mode, which is sufficient for `exec` against
#     a local `.sif`.
#   - The `.sif` produced by `pkgs.singularity-tools.buildImage` is a real
#     squashfs file — both `apptainer exec` and `singularity exec` (CE) work
#     directly against it, no convert step.
{ pkgs, containers, images, tests }:

let
  inherit (tests) fixtures synthesiseReads synthesiseBam scripts;

  # Stage the fixtures into a single tree the test can copy into the VM in one
  # `cp -r`. Keeps the testScript readable and avoids repeating the file list
  # in every machine check.
  fixtureDir = pkgs.runCommand "viro-vm-test-fixtures" { } ''
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

  # We write the per-container script body to a file inside the VM, then have
  # the runtime mount /work and execute `bash /work/run.sh`. This avoids any
  # quoting hell from interpolating the script through `<runtime> ... bash -c`.
  scriptFile = name: pkgs.writeText "viro-vm-${name}-script.sh" scripts.${name};

  # Common NixOS module: docker daemon + apptainer (= "singularity" via the
  # NixOS module) + singularity-CE installed under its store path only (NOT in
  # systemPackages, to avoid colliding with apptainer's `singularity` symlink).
  vmModule = { pkgs, ... }: {
    virtualisation = {
      # Default disk size (1 GB) is too small once docker has loaded a 1 GB
      # streamed tarball and the .sif sits in /nix/store. Bump generously.
      diskSize = 8192;
      memorySize = 4096;
      cores = 2;

      docker.enable = true;
    };

    # NixOS exposes apptainer as `apptainer` AND as `singularity` when the
    # module is enabled with `pkgs.apptainer`. The setuid wrapper bits this
    # module installs (under /run/wrappers/bin) are needed for some bind-mount
    # paths apptainer takes; enabling the module is the supported way to get
    # those configured. We do NOT enable the module with `pkgs.singularity`,
    # because doing so would conflict on the `singularity` name; SingularityCE
    # is invoked by absolute store path below and runs in unprivileged-userns
    # mode (which is the common case on HPC sites that don't grant setuid).
    programs.singularity = {
      enable = true;
      package = pkgs.apptainer;
    };

    # User namespaces — both forks rely on these for their rootless execution
    # path. NixOS defaults are fine; setting explicitly so a future default
    # change doesn't silently break this test layer.
    boot.kernel.sysctl."user.max_user_namespaces" = 28633;

    # Apptainer's default mount config bind-mounts `/etc/localtime` from the
    # host into the container. Bare NixOS test VMs don't have `/etc/localtime`
    # by default, which makes apptainer fail at container-creation with
    # `mount source /etc/localtime doesn't exist`. Setting a timezone causes
    # NixOS to create the file. (SingularityCE has the same default; same fix.)
    time.timeZone = "UTC";

    # Bake `pkgs.singularity` into the system closure so its store path is
    # realised on the VM disk without being on PATH. Wrapping it in an attrset
    # under `system.extraDependencies` is the idiomatic way to pin a derivation
    # into a NixOS system without registering it for use.
    system.extraDependencies = [ pkgs.singularity ];

    environment.systemPackages = [ pkgs.coreutils pkgs.bash ];
  };

  # The SingularityCE binary path. Captured once so the testScript can refer
  # to it by Nix interpolation rather than discovering it at runtime.
  singularityCE = "${pkgs.singularity}/bin/singularity";

  # Build a single VM test exercising all three runtimes against one container.
  # One VM, three phases (docker, apptainer, singularity-CE) — VM startup
  # dominates wall time, so sharing a VM across the three phases is the right
  # tradeoff. Each phase is its own `subtest`, so failure output identifies
  # exactly which runtime broke.
  mkVmTest = name: pkgs.testers.nixosTest {
    name = "viro-vm-${name}";

    nodes.machine = vmModule;

    testScript = ''
      machine.start()
      machine.wait_for_unit("multi-user.target")
      machine.wait_for_unit("docker.service")

      # Helper: wipe and re-stage /work between phases so a previous phase's
      # outputs can't mask a regression in the next one.
      def stage_work():
          machine.succeed("rm -rf /work && mkdir -p /work")
          machine.succeed("cp -r ${fixtureDir}/. /work/")
          machine.succeed("cp ${scriptFile name} /work/run.sh")
          machine.succeed("chmod +x /work/run.sh")

      stage_work()

      # ------- Phase 1: Docker -------
      # The `streamLayeredImage` output is a script that emits an OCI tarball
      # on stdout. Pipe straight into `docker load`.
      with subtest("docker run for ${name}"):
          machine.succeed("${images.mkDocker name containers.${name}} | docker load")
          # Reference the loaded image by its `name:tag` pair, set in images.nix.
          out = machine.succeed(
              "docker run --rm "
              "-v /work:/work -w /work "
              "viro-${name}-nix:demo "
              "bash /work/run.sh 2>&1"
          )
          machine.log("[docker/${name}] " + out)
          # Sanity: the script bodies always print at least one diagnostic line
          # ("mapped reads: N", "pysam: N alignments", etc.) when they really
          # ran the tools. An empty stdout is suspicious even with exit 0.
          assert out.strip(), "docker run produced no stdout for ${name}"

      # ------- Phase 2: Apptainer (LF fork) -------
      stage_work()
      with subtest("apptainer exec for ${name}"):
          # apptainer needs a writable home for its session dir; /root is fine
          # in this VM. `--bind` mounts /work read-write into the container.
          out = machine.succeed(
              "HOME=/root APPTAINER_TMPDIR=/tmp "
              "apptainer exec "
              "--bind /work:/work --pwd /work "
              "${images.mkSif name containers.${name}} "
              "bash /work/run.sh 2>&1"
          )
          machine.log("[apptainer/${name}] " + out)
          assert out.strip(), "apptainer exec produced no stdout for ${name}"

      # ------- Phase 3: SingularityCE (Sylabs fork) -------
      # Same .sif file, executed by the OTHER fork. The two forks diverged in
      # 2021; verifying the same image runs cleanly under both surfaces drift
      # in image-format compatibility, default mount/bind behaviour, and
      # userns handling that one fork would catch but the other wouldn't.
      #
      # Invoked by absolute store path because we deliberately don't put
      # `pkgs.singularity` on PATH (it would collide with apptainer's
      # `singularity` symlink). `SINGULARITY_TMPDIR` is the CE-fork-specific
      # name for the same env var apptainer reads as `APPTAINER_TMPDIR`.
      stage_work()
      with subtest("singularity-ce exec for ${name}"):
          out = machine.succeed(
              "HOME=/root SINGULARITY_TMPDIR=/tmp "
              "${singularityCE} exec "
              "--bind /work:/work --pwd /work "
              "${images.mkSif name containers.${name}} "
              "bash /work/run.sh 2>&1"
          )
          machine.log("[singularity-ce/${name}] " + out)
          assert out.strip(), "singularity-ce exec produced no stdout for ${name}"
    '';
  };
in
{
  # Map a `containers` attrset to per-container VM checks. Returns:
  #   { "vm-<name>" = <nixosTest derivation>; ... }
  # Each derivation runs the docker / apptainer / singularity-CE phases in
  # named subtests, so `nix flake check` failure output identifies exactly
  # which runtime broke without needing three separate top-level checks per
  # container (which would each pay the VM-startup cost independently).
  forContainers = containerSet:
    let
      names = builtins.attrNames containerSet;
      mk = name: { "vm-${name}" = mkVmTest name; };
    in
    pkgs.lib.foldl' (acc: name: acc // mk name) { } names;
}
