# aarch64-via-binfmt VM smoke test for the alignment container.
#
# The host is x86_64. There is no aarch64 hardware in this loop. The flake
# cross-builds an aarch64 OCI image (`alignment-docker-aarch64-linux` in
# flake.nix) using `pkgsCross.aarch64-multiplatform`, then this test boots a
# NixOS VM that registers binfmt_misc handlers for aarch64-linux ELF via
# `boot.binfmt.emulatedSystems`. With those handlers in place, the kernel
# transparently routes any aarch64 ELF exec through `qemu-aarch64`. Both
# `docker run` (against the loaded aarch64 image) and `apptainer exec`
# (against an aarch64 .sif converted in-VM from the docker tarball) end up
# running the alignment smoke script with minimap2/samtools/bedtools as
# real aarch64 binaries under qemu-user emulation.
#
# Why only the alignment container: the other five containers have hard
# upstream blockers on aarch64 in the pinned nixpkgs (`fastp` is x86-only,
# `polars` carries `meta.broken = aarch64`, openjdk21+jlink crosses fragile,
# ampligone's Python C-extensions don't cross cleanly). Alignment's closure
# (minimap2, samtools, bedtools, bash, coreutils, python3) all cross-build
# and run cleanly under emulation. This is a capability demo, not full
# aarch64 support.
#
# Why no SingularityCE in this variant: SingularityCE's setuid path interacts
# poorly with the binfmt+qemu-user combo (the static qemu interpreter is
# loaded into the child via the kernel's `F` flag, but SingularityCE's
# privilege-drop flow re-execs through a wrapper that's already aarch64,
# which the setuid-root entry has to handle before binfmt fires; in practice
# we hit `Failed to set effective UID` errors on the unprivileged-userns
# fallback path under emulation). Docker and apptainer both work cleanly,
# which is sufficient for a capability demo. The host-x86_64 vm-alignment
# check still exercises all three runtimes.
#
# Why one VM instead of three (one per runtime): VM startup dominates wall
# time, especially when the kernel boots with binfmt + the qemu-user-static
# closure on disk. Docker phase + apptainer phase as named subtests inside
# one VM, mirroring the structural choice in nix/vm-tests.nix.
{ pkgs, tests, imagesCross, containersCross }:

let
  inherit (tests) fixtures synthesiseReads synthesiseBam scripts;

  # Same fixture-staging pattern as nix/vm-tests.nix. Reuses the shared
  # `synthesiseBam` etc. so this aarch64 test is exercising exactly the same
  # inputs and same script body as the x86_64 alignment check. The only thing
  # that changes is the architecture of the binaries doing the work.
  fixtureDir = pkgs.runCommand "viro-vm-test-fixtures-aarch64" { } ''
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

  # The aarch64 alignment image, cross-built. This is a shell script that
  # streams an OCI tarball on stdout; the layers contain aarch64 ELF
  # binaries. The script itself is x86_64 (it runs on the host inside the
  # VM, not inside any container).
  alignmentDockerAarch64 = imagesCross.mkDocker "alignment-aarch64" containersCross.alignment;

  # Same script as the x86_64 alignment check (`tests.scripts.alignment`),
  # so any divergence between architectures is a real architectural
  # difference, not a script change.
  scriptFile = pkgs.writeText "viro-vm-alignment-aarch64-script.sh" scripts.alignment;
in
{
  vmAlignmentAarch64 = pkgs.testers.nixosTest {
    name = "viro-vm-alignment-aarch64";

    nodes.machine = { pkgs, ... }: {
      virtualisation = {
        # Bigger than the x86_64 default; qemu-user-static + the aarch64
        # closure pull noticeably more onto the VM disk, and `apptainer
        # build` materialises an extra rootfs tree.
        diskSize = 12288;
        memorySize = 4096;
        cores = 2;
        docker.enable = true;
      };

      # The whole point of this test. NixOS handles registration of the
      # binfmt_misc handlers; we ask for the `preferStaticEmulators` mode
      # which (a) selects a *statically linked* qemu interpreter from
      # pkgs.pkgsStatic and (b) flips on the binfmt `F` (fixBinary) flag
      # by default. Together those let the kernel pre-open the qemu
      # interpreter into its own state at registration time, so an
      # aarch64 ELF exec inside any container (different mount namespace)
      # still finds a working interpreter. Without preferStaticEmulators,
      # the default is the dynamically-linked `qemu-aarch64-binfmt-P`
      # wrapper which fails inside Docker's namespaces (interpreter path
      # not visible, even with F set on the registration, because the
      # preloaded interpreter is itself dynamically linked and its libs
      # aren't in the container).
      boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
      boot.binfmt.preferStaticEmulators = true;

      # Apptainer needs a writable session dir + setuid wrappers. Same
      # configuration as the host-arch VM module.
      programs.singularity = {
        enable = true;
        package = pkgs.apptainer;
      };

      boot.kernel.sysctl."user.max_user_namespaces" = 28633;
      time.timeZone = "UTC";

      environment.systemPackages = [ pkgs.coreutils pkgs.bash pkgs.file ];
    };

    testScript = ''
      machine.start()
      machine.wait_for_unit("multi-user.target")
      machine.wait_for_unit("docker.service")

      # Wait for the kernel binfmt_misc filesystem to actually be mounted +
      # for the systemd-binfmt service that registers handlers from
      # /etc/binfmt.d/*.conf to have completed. On NixOS,
      # `boot.binfmt.emulatedSystems` writes a unit that runs
      # `systemd-binfmt`, but that unit is not transitively required by
      # multi-user.target on every nixpkgs revision; explicitly wait for it
      # so the registration race resolves before docker tries to exec
      # aarch64 binaries.
      machine.wait_for_unit("systemd-binfmt.service")

      # Sanity: confirm binfmt_misc is registered for aarch64 BEFORE we try
      # to run anything. If this fails, qemu-user isn't wired up and every
      # later step would fail in confusing ways.
      #
      # NB: NixOS' `boot.binfmt.emulatedSystems` registers the handler
      # under the system name (`aarch64-linux`), not the qemu binary
      # name (`qemu-aarch64`) that you'd see if you registered binfmt by
      # hand from the qemu source tree. Name reflects who owns the
      # registration, not the interpreter.
      machine.succeed("test -f /proc/sys/fs/binfmt_misc/aarch64-linux")
      reg = machine.succeed("cat /proc/sys/fs/binfmt_misc/aarch64-linux")
      machine.log("[binfmt registration]\n" + reg)
      assert "enabled" in reg, "binfmt_misc qemu-aarch64 handler not enabled"

      def stage_work():
          machine.succeed("rm -rf /work && mkdir -p /work")
          machine.succeed("cp -r ${fixtureDir}/. /work/")
          machine.succeed("cp ${scriptFile} /work/run.sh")
          machine.succeed("chmod +x /work/run.sh")
          # Same UID-10001 chown as nix/vm-tests.nix's stage_work: images
          # run as appuser (10001) per the User config in nix/images.nix;
          # without this, samtools/minimap2 can't write outputs to the
          # bind-mounted /work and the test silently produces empty files
          # (mapped reads: 0, [: : integer expected).
          machine.succeed("chown -R 10001:10001 /work")

      stage_work()

      # ------- Phase 1: Docker (aarch64 image under binfmt) -------
      with subtest("docker run aarch64 alignment"):
          machine.succeed("${alignmentDockerAarch64} | docker load")

          # Proof-of-aarch64: pick a binary out of the loaded image and ask
          # `file` what architecture it is. We do this by extracting the
          # tarball into a scratch dir rather than running the image (so it
          # is independent of qemu actually working).
          machine.succeed("mkdir -p /tmp/aarch64-probe")
          machine.succeed(
              "${alignmentDockerAarch64} > /tmp/aarch64-probe/img.tar"
          )
          machine.succeed(
              "cd /tmp/aarch64-probe && tar -xf img.tar"
          )
          # Find a layer tarball, extract one bin, file it.
          # streamLayeredImage emits one layer per /nix/store path, so
          # minimap2 lives in its own layer. Extract every layer into a
          # scratch dir and `file` the resulting binary. Brute-force
          # rather than scanning tar listings because `tar -tf` listing
          # normalisation differs between busybox/GNU and was masking the
          # match in earlier iterations.
          probe = machine.succeed(
              "set -eu; cd /tmp/aarch64-probe; "
              "rm -rf layer-extract && mkdir -p layer-extract; "
              "for layer in $(find . -name 'layer.tar'); do "
              "  tar -C layer-extract -xf \"$layer\" 2>/dev/null || true; "
              "done; "
              "bin=$(find layer-extract -name minimap2 -type f -path '*/bin/*' | head -n1); "
              "test -n \"$bin\" || { echo 'minimap2 not found in any layer'; find layer-extract -maxdepth 4 -type d; exit 1; }; "
              "file -L \"$bin\""
          )
          machine.log("[file minimap2] " + probe)
          assert "aarch64" in probe or "ARM aarch64" in probe, \
              "minimap2 in the loaded image is not aarch64: " + probe

          # Now actually run the image. Docker on Linux honours the host's
          # binfmt_misc registration; an aarch64 ELF exec inside the
          # container goes through qemu-aarch64 transparently, no
          # `--platform` needed because we never tagged the image with
          # x86_64 metadata to begin with.
          # `uname -m` is the cleanest proof that the kernel's binfmt
          # routing is in effect: the binary itself is aarch64 and reports
          # its host architecture from `utsname.machine`. With
          # preferStaticEmulators (set in the VM module above), the
          # kernel preloads pkgsStatic's qemu-aarch64 into binfmt with
          # the F flag, so exec'ing this aarch64 ELF inside a docker
          # container Just Works without bind-mounting the qemu
          # interpreter or carrying its dynamic deps.
          uname_out = machine.succeed(
              "docker run --rm viro-alignment-aarch64-nix:demo uname -m 2>&1"
          )
          machine.log("[docker uname -m] " + uname_out)
          # docker on Linux prints a WARNING to stderr when the image
          # platform doesn't match the host's, even though the run
          # succeeds via binfmt. Match `aarch64` as a substring of the
          # combined stream rather than requiring it be the only line.
          assert "aarch64" in uname_out, \
              "docker uname -m did not report aarch64: " + uname_out

          # qemu-aarch64 user emulation in nixpkgs' pinned qemu (10.2.x)
          # has issues translating some NEON intrinsics that minimap2
          # uses; without a CPU pin it segfaults during seed-and-extend.
          # `QEMU_CPU=max` enables all features qemu actually models;
          # cortex-a72 also works and is a more conservative choice. We
          # pass via `-e` so the env var reaches the binfmt-spawned
          # interpreter (qemu reads it before translating syscalls).
          out = machine.succeed(
              "docker run --rm "
              "-e QEMU_CPU=max "
              "-v /work:/work -w /work "
              "viro-alignment-aarch64-nix:demo "
              "bash /work/run.sh 2>&1"
          )
          machine.log("[docker/alignment-aarch64] " + out)
          assert "mapped reads:" in out, \
              "alignment script did not produce expected output: " + out

      # ------- Phase 2: Apptainer (aarch64 .sif under binfmt) -------
      # Building a .sif up front via `pkgsCross.singularity-tools.buildImage`
      # would require booting an aarch64 qemu-system VM at flake-build time
      # (the singularity-tools builder uses runInLinuxVM matched to the
      # target system), which is slow and fragile. Instead we let apptainer,
      # already running inside this binfmt-enabled VM, build the .sif from
      # the loaded docker image. This uses the same emulation path the
      # alignment workload itself uses, and it's the path a user would take
      # in practice (build once cross, ship the OCI tarball, convert
      # locally to .sif).
      stage_work()
      with subtest("apptainer exec aarch64 alignment"):
          machine.succeed(
              "HOME=/root APPTAINER_TMPDIR=/tmp "
              "apptainer build /tmp/alignment-aarch64.sif "
              "docker-daemon://viro-alignment-aarch64-nix:demo 2>&1"
          )
          uname_out = machine.succeed(
              "HOME=/root APPTAINER_TMPDIR=/tmp "
              "apptainer exec /tmp/alignment-aarch64.sif uname -m"
          )
          machine.log("[apptainer uname -m] " + uname_out)
          assert "aarch64" in uname_out, \
              "apptainer uname -m did not report aarch64: " + uname_out

          out = machine.succeed(
              "HOME=/root APPTAINER_TMPDIR=/tmp "
              "apptainer exec "
              "--bind /work:/work --pwd /work "
              "/tmp/alignment-aarch64.sif "
              "bash /work/run.sh 2>&1"
          )
          machine.log("[apptainer/alignment-aarch64] " + out)
          assert "mapped reads:" in out, \
              "alignment script did not produce expected output: " + out
    '';
  };
}
