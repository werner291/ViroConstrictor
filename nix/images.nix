# Build a docker (streamLayeredImage) and a singularity (.sif) output from
# the same closure.
#
# Both formats now go through nix/trim.nix's `mkTrimmedRoot`, which
# materialises the entire closure as a single self-contained rootfs derivation
# and applies image-level cleanup (python tests/__pycache__/.pyi, share/locale,
# *.a, share/{man,info,doc}, include/, pkgconfig/cmake metadata) before the
# bytes ever reach the image format. The underlying nixpkgs derivations stay
# untouched and cached; only the per-image rootfs gets trimmed.
#
# Trade-off vs the pre-trim layout: we ship a single fat layer per image
# (Docker) / one squashfs (SIF) instead of a per-store-path layer split. For
# six demo containers this is fine; layer reuse across containers was already
# limited because each container ships its own python env.
pkgs:

let
  trim = import ./trim.nix { inherit pkgs; };
in
{
  # Docker / OCI: emit a single customisation-layer tarball whose contents
  # are trimmedRoot's tree (nix/store/..., etc/, tmp/). We bypass
  # streamLayeredImage's default `symlinkJoin contents` staging because
  # symlinkJoin produces absolute symlinks pointing into trimmedRoot's
  # own /nix/store path, and `tar --hard-dereference` (the streamLayeredImage
  # default) does NOT follow symbolic links: the tarball would then contain
  # only symlink stubs, not the trimmed bytes.
  #
  # Instead pass an empty `contents` and use `extraCommands` to populate the
  # layer dir from trimmedRoot via `cp -a ... /.`, which materialises real
  # files. `includeStorePaths = false` keeps the streamScript from emitting
  # per-store-path layers for trimmedRoot's closure (which is empty by
  # construction, see unsafeDiscardReferences in nix/trim.nix).
  mkDocker = name: closure:
    let
      rootfs = trim.mkTrimmedRoot name closure;
    in
    pkgs.dockerTools.streamLayeredImage {
      name = "viro-${name}-nix";
      tag = "demo";
      contents = [ ];
      extraCommands = ''
        cp -a ${rootfs}/. ./
        chmod -R u+w .
        # Restore the world-writable + sticky bit on /tmp. Nix's post-build
        # store lockdown strips u+w from store paths, taking 1777 down to
        # 0555 inside the rootfs derivation; the `chmod -R u+w .` above only
        # adds back user-write, leaving group/other write missing. Without
        # this, FastQC's javax.imageio temp-file write fails with
        # AccessDeniedException when running as appuser.
        chmod 1777 ./tmp
      '';
      includeStorePaths = false;
      config = {
        # bashInteractive lives inside the trimmed rootfs at its original
        # /nix/store/...-bash-...-interactive/bin/bash path; references in
        # Cmd are plain strings (no nix store-path tracking), so this resolves
        # at container start against the image's own /nix/store tree.
        Cmd = [ "${pkgs.bashInteractive}/bin/bash" ];
        Env = [ "PATH=/bin:/usr/bin" ];
        # Match the conda containers (`USER appuser` with UID 10001) so
        # bind-mounted output files end up owned by the same UID across both
        # image families. A drop-in replacement for the conda containers
        # should not silently change file ownership semantics on the host.
        User = "10001:10001";
      };
    };

  # Singularity .sif: builds the squashfs from trimmedRoot directly. We don't
  # use singularity-tools.buildImage here because that helper hard-codes a
  # closure-walking copy loop that would re-introduce the untrimmed originals
  # alongside trimmedRoot. Instead we replicate its VM-based approach but copy
  # the trimmed rootfs CONTENTS into the image filesystem in one shot, then
  # let `singularity build` package it.
  #
  # singularity .sif files don't carry a baked-in default user the way docker
  # does. apptainer/singularity always run as the invoking host user (unless
  # `--fakeroot` or setuid is in play), so no User attr is meaningful here.
  mkSif = name: closure:
    let
      rootfs = trim.mkTrimmedRoot name closure;
      runScript = pkgs.writeScript "run-script.sh" ''
        #!/bin/sh
        set -e
        exec /bin/sh
      '';
    in
    pkgs.vmTools.runInLinuxVM (pkgs.runCommand "singularity-image-viro-${name}-nix.sif"
      {
        __structuredAttrs = true;
        nativeBuildInputs = [ pkgs.singularity pkgs.e2fsprogs pkgs.util-linux ];
        strictDeps = true;
        # writeClosure walks references; since rootfs uses
        # unsafeDiscardReferences this stays small (rootfs itself + the run
        # script + bash). All the actual package bytes live INSIDE rootfs's
        # $out and are copied content-wise below.
        layerClosure = pkgs.writeClosure [ pkgs.bashInteractive runScript rootfs ];
        preVM = pkgs.vmTools.createEmptyImage {
          size = 6144;   # uncompressed Clean closure ~3 GB pre-trim
          fullName = "singularity-run-disk";
          destination = "disk-image";
        };
        memSize = 2048;
      } ''
        mkdir workspace
        mkfs -t ext3 -b 4096 /dev/${pkgs.vmTools.hd}
        mount /dev/${pkgs.vmTools.hd} workspace
        mkdir -p workspace/img
        cd workspace/img
        mkdir proc sys dev

        # Stage the support closure (bash + run script + their deps) as
        # /nix/store/... entries. These are all real (not trimmed) because
        # they are tiny and untouched by the image cleanup.
        mkdir -p ./${builtins.storeDir}
        while IFS= read -r f; do
          [ -n "$f" ] || continue
          cp -ar "$f" "./$f"
        done < "$layerClosure"

        # Lay the trimmed rootfs CONTENTS over the staging tree. cp -a
        # preserves intra-closure symlinks; the trailing "/." copies
        # contents-of, not the rootfs dir itself, so etc/ and nix/store/
        # land at the image root.
        cp -a "${rootfs}/." ./

        # Same /tmp permission restore as mkDocker: nix's store lockdown
        # collapses 1777 to 0555, leaving FastQC's javax.imageio temp file
        # write unable to create cache files when running as appuser.
        chmod 1777 ./tmp

        # /bin/sh -> bash, mirroring singularity-tools.buildImage.
        mkdir -p bin
        if [ ! -e bin/sh ]; then
          ln -s ${pkgs.lib.getExe pkgs.bashInteractive} bin/sh
        fi

        mkdir -p .singularity.d/env
        cp "${runScript}" .singularity.d/runscript
        touch .singularity.d/env/94-appsbase.sh

        cd ..
        mkdir -p /var/lib/singularity/mnt/session
        echo "root:x:0:0:System administrator:/root:/bin/sh" > /etc/passwd
        echo > /etc/resolv.conf
        TMPDIR="$(pwd -P)" singularity build "$out" ./img
      ''
    );
}
