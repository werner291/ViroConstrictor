# Experimental nix flake building all six ViroConstrictor containers as both
# Docker / OCI tarballs and Singularity .sif files. Opt-in, parallel to the
# existing dockerfile + conda pipeline; nothing in containers/ or the
# snakemake rules is changed by this file's presence. See nix/README.md.
{
  description = "Experimental nix-built containers for ViroConstrictor (#161)";

  # nixos-unstable = nixpkgs's rolling line, gated by Hydra CI. The
  # "unstable" tag refers to the NixOS release channel, not package quality;
  # we're using nixpkgs as a package source here, not building NixOS.
  # Pinned via flake.lock; bump with `nix flake update`.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";

      # nixpkgs + the overlay that adds RIVM tools and slim overrides as
      # standard pkgs.* attrs, so containers.nix can use them by bare name.
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ (import ./nix/overlay.nix) ];
      };

      # Cross-pkgs for aarch64-linux (host stays x86_64). Used to cross-build
      # an aarch64 alignment image whose runtime is then exercised under
      # binfmt_misc + qemu-user emulation inside a NixOS test VM. See
      # nix/vm-tests-aarch64.nix and the README section.
      #
      # Cross path was chosen over `import nixpkgs { system = "aarch64-linux"; }`
      # because the alignment closure (minimap2, samtools, bash, coreutils,
      # bare python3) cross-compiles cleanly under nixpkgs' standard cross
      # framework, so the build itself runs natively on x86_64 with no host
      # binfmt registration required. Only the *runtime* needs emulation, and
      # that happens inside the VM where we register binfmt explicitly.
      pkgsAarch64Cross = pkgs.pkgsCross.aarch64-multiplatform;

      # name → list of nixpkgs attrs that make up the container's closure
      containers = import ./nix/containers.nix pkgs;
      # Same builder, instantiated against the aarch64 cross-pkgs. We only
      # consume `containersAarch64.alignment` — see nix/README.md for why
      # the other five containers are aarch64-blocked at the nixpkgs layer.
      containersAarch64 = import ./nix/containers.nix pkgsAarch64Cross;
      # { mkDocker, mkSif } — turn a closure into the corresponding image format
      images = import ./nix/images.nix pkgs;
      # Same builders bound to the cross-pkgs; produces aarch64 OCI tarballs
      # whose layers contain aarch64 ELF binaries.
      imagesAarch64 = import ./nix/images.nix pkgsAarch64Cross;
      # { forContainers, fixtures, scripts, ... } — closure-level smoke tests
      # plus the fixture / script attrsets that nix/vm-tests.nix consumes.
      tests = import ./nix/tests.nix { inherit pkgs; };
      # { forContainers } — boots a NixOS VM per container and runs the same
      # script body inside the actual built docker / singularity images.
      vmTests = import ./nix/vm-tests.nix {
        inherit pkgs containers images tests;
      };
      # Single-container aarch64 VM check: boots a NixOS VM with binfmt_misc
      # + qemu-user registered for aarch64-linux, loads the cross-built
      # aarch64 alignment image, and runs the same alignment smoke script
      # under both docker and apptainer. SingularityCE is omitted on
      # aarch64; rationale documented inline in that file.
      vmTestsAarch64 = import ./nix/vm-tests-aarch64.nix {
        inherit pkgs tests;
        imagesCross = imagesAarch64;
        containersCross = containersAarch64;
      };

      # Per-CPU-baseline polars variants. See nix/polars-variants.nix.
      polarsVariants = import ./nix/polars-variants.nix { inherit pkgs; };
      cleanBuilder = import ./nix/clean-builder.nix { inherit pkgs; };

      # Match the conda Clean container, which ships `compat` and `32` only.
      # `64` (AVX-512) is not in the conda image; we omit it here for parity.
      # The override mechanism would build it just fine, see polars-variants.nix.
      cleanVariantNames = [ "compat" "32" ];

      # { compat = <closure>; "32" = <closure>; } — Clean closures pinned
      # to one polars runtime variant each.
      cleanVariantClosures = pkgs.lib.genAttrs cleanVariantNames
        (v: cleanBuilder.mkCleanClosure polarsVariants.byVariant.${v});

      names = builtins.attrNames containers;

      # { alignment-docker, alignment-sif, clean-docker, ... } — one of each per container
      packages = pkgs.lib.foldl' (acc: name: acc // {
        "${name}-docker" = images.mkDocker name containers.${name};
        "${name}-sif"    = images.mkSif    name containers.${name};
      }) { } names // {
        # aarch64 cross-built alignment image. The streamLayeredImage script
        # itself is an x86_64 shell script (it just emits a tarball on
        # stdout), but the layers it streams contain aarch64 ELF binaries.
        # `file` on any binary inside, or `uname -m` from a `docker run`
        # under binfmt emulation, will report `aarch64`.
        alignment-docker-aarch64-linux = imagesAarch64.mkDocker "alignment-aarch64" containersAarch64.alignment;

        # Kept reachable as a package (rather than under `checks`) because the
        # QEMU user-mode emulator intermittently SIGSEGVs running minimap2 on
        # an x86_64 host; we don't want that flake to gate `nix flake check`.
        vm-alignment-aarch64 = vmTestsAarch64.vmAlignmentAarch64;

        # Optional VM check that runs the alignment container against real
        # SARS-CoV-2 amplicon reads from nf-core/test-datasets, fetched via
        # fetchurl with a pinned hash. Kept out of `checks` because the fetch
        # needs internet on first build; cached afterwards.
        vm-alignment-real-reads = import ./nix/vm-test-real-reads.nix {
          inherit pkgs images containers;
        };
      } // pkgs.lib.foldl' (acc: v: acc // {
        # Per-CPU-baseline Clean image variants. Each pulls exactly one
        # `_polars_runtime_<v>` directory, mirroring the conda Clean image's
        # split. Verified by the `vm-clean-${v}` checks below.
        "clean-${v}-docker" = images.mkDocker "clean-${v}" cleanVariantClosures.${v};
        "clean-${v}-sif"    = images.mkSif    "clean-${v}" cleanVariantClosures.${v};
      }) { } cleanVariantNames;

      vmTestsCleanVariants = import ./nix/vm-tests-clean-variants.nix {
        inherit pkgs tests images cleanVariantClosures;
      };

      # `nix flake check` smoke-tests every container end-to-end. Two layers:
      # 1. Closure-level checks (fast, hermetic, no docker/apptainer needed).
      # 2. VM checks: load the actual image into a NixOS VM and run the same
      #    script under both `docker run` and `singularity exec`.
      # Plus per-CPU-baseline VM checks for the Clean image variants.
      #
      # The aarch64 cross-build VM check is exposed as a package
      # (`packages.x86_64-linux.vm-alignment-aarch64`) but kept out of `checks`
      # because QEMU user-mode emulation on x86_64 hosts intermittently
      # SIGSEGVs running minimap2; the cross-build itself is fine, the
      # emulator isn't. Run it manually via `nix build .#vm-alignment-aarch64`
      # if you want to exercise it.
      checks = tests.forContainers containers
            // vmTests.forContainers containers
            // vmTestsCleanVariants.forVariants cleanVariantNames;

      # `nix run .#load-<name>` builds + loads a container into the local docker daemon
      apps = pkgs.lib.foldl' (acc: name: acc // {
        "load-${name}" = {
          type = "app";
          program = toString (pkgs.writeShellScript "load-${name}" ''
            set -eu
            ${packages."${name}-docker"} | ${pkgs.docker}/bin/docker load
          '');
        };
      }) { } names;
    in
    {
      packages.${system} = packages;
      checks.${system} = checks;
      apps.${system} = apps;
    };
}
