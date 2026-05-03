# Image-level cleanup: copy a container's closure into a single derivation,
# then strip cruft (python tests, __pycache__, locale data, *.a, etc.) before
# the image format (Docker tarball, .sif squashfs) is assembled around it.
#
# Crucially, the underlying nixpkgs derivations (python3, biopython, openjdk,
# fontconfig, ...) are NOT modified. The cleanup happens on COPIES of those
# store paths, materialised once per image, so cache hits across packages are
# preserved. A previous attempt at trimming via overlay-level overrides was
# abandoned because it triggered hours-long cascade rebuilds (nodejs,
# aws-cpp-sdk). The trade-off here: each image gets a single fat
# "rootfs" layer instead of one-layer-per-store-path, which is fine for a
# demo and is what makes the deletions visible to the image tooling.
#
# Output layout: $out/nix/store/<hash>-<name>/... with one directory
# per closure entry, mirroring the original /nix/store paths so that all
# RPATH / shebang / hard-coded references inside the binaries still resolve
# inside the image. /etc and /tmp are also seeded here (passwd/group with
# UID 10001 appuser, sticky /tmp) so the higher-level image builders don't
# need to layer them separately.
{ pkgs }:

let
  inherit (pkgs) lib;

  # Cleanup script executed against $out after the closure is copied.
  # Justifications inline; keep grouped by category so adding/removing items
  # is easy to review.
  cleanupScript = ''
    root="$out"

    # Make everything writable; nix store copies come in 0555/0444. We drop
    # write back at the end (image tools will re-stamp permissions anyway).
    chmod -R u+w "$root/nix/store"

    # ---- Python: per-package tests/, docs/, examples/ trees -------------
    # Most python packages ship their own test suite + sphinx sources under
    # site-packages. Pure development overhead at runtime; pandas alone is
    # ~53 MB of tests, numpy another ~13 MB.
    find "$root/nix/store" -type d \
      \( -path '*/site-packages/*/tests' \
      -o -path '*/site-packages/*/test'  \
      -o -path '*/site-packages/*/docs'  \
      -o -path '*/site-packages/*/doc'   \
      -o -path '*/site-packages/*/examples' \
      -o -path '*/site-packages/*/example'  \
      \) -prune -exec rm -rf {} + 2>/dev/null || true

    # ---- Python: __pycache__ --------------------------------------------
    # Bytecode caches are regenerated on first import. Risk: under read-only
    # mounts (Apptainer/SingularityCE without --writable-tmpfs) Python
    # warns/slows on first import. Verified by the vm-clean-32 and
    # vm-core-scripts tests under all three runtimes.
    find "$root/nix/store" -type d -name '__pycache__' \
      -prune -exec rm -rf {} + 2>/dev/null || true

    # ---- Python: type stubs ---------------------------------------------
    # .pyi files are pure development metadata, not imported at runtime.
    find "$root/nix/store" -type f -name '*.pyi' -delete 2>/dev/null || true

    # ---- Static archives -------------------------------------------------
    # *.a will not be linked at runtime in a closed image. ~65 MB on
    # python-heavy envs (numpy, openblas, htslib, samtools).
    find "$root/nix/store" -type f -name '*.a' -delete 2>/dev/null || true

    # ---- Locale + docs in share/ ----------------------------------------
    # share/locale: glibc/perl/etc. translations, ~85 MB combined; the
    # containers run with LANG=C so nothing reads these. share/info and
    # share/man: GNU info pages and manpages, never consulted from a
    # snakemake rule.
    find "$root/nix/store" -type d \
      \( -path '*/share/locale' \
      -o -path '*/share/info'   \
      -o -path '*/share/man'    \
      -o -path '*/share/doc'    \
      -o -path '*/share/gtk-doc' \
      \) -prune -exec rm -rf {} + 2>/dev/null || true

    # ---- Header files ----------------------------------------------------
    # No compilation happens at runtime in any rule. include/ trees come
    # along for free with -dev outputs of some packages.
    find "$root/nix/store" -type d -name 'include' \
      -prune -exec rm -rf {} + 2>/dev/null || true

    # ---- pkgconfig + cmake build metadata --------------------------------
    # Build-time metadata; runtime never looks at it.
    find "$root/nix/store" -type d \
      \( -path '*/lib/pkgconfig' \
      -o -path '*/share/pkgconfig' \
      -o -path '*/lib/cmake' \
      -o -path '*/share/cmake' \
      -o -path '*/share/aclocal' \
      \) -prune -exec rm -rf {} + 2>/dev/null || true

    # ---- Dangling symlinks left by the FHS overlay -----------------------
    # The buildEnv-produced /lib, /share, ... layer is symlinks pointing into
    # /nix/store/<hash>/...; deleting the targets above leaves stubs behind
    # (e.g. /lib/python3.13/site-packages/__pycache__ -> ...env.../__pycache__).
    # Python tolerates these but tar packs the dead symlinks anyway. Strip
    # them so the image stays clean.
    find "$root" -xtype l -delete 2>/dev/null || true
  '';

  # Build a single rootfs derivation from a list of contents (the same shape
  # passed to dockerTools/singularity-tools). The recursive closure is
  # discovered via pkgs.closureInfo at build time and walked in bash; we
  # don't IFD-read the store-paths file at eval time.
  #
  # The derivation explicitly disables nix's reference scanner via
  # unsafeDiscardReferences: we deliberately want the trimmed copies inside
  # $out to NOT propagate the original (untrimmed) store paths as runtime
  # dependencies. Without this, the downstream image format would re-include
  # the untrimmed originals as separate layers / cp -ar them into the
  # squashfs, defeating the cleanup. The trimmed rootfs is self-contained:
  # all RPATH / shebang references inside it point to /nix/store/<hash>
  # paths that ARE materialised inside $out itself, so once the image
  # is loaded those references resolve against the image's own /nix/store.
  mkTrimmedRoot = name: contents:
    let
      closureInfo = pkgs.closureInfo { rootPaths = contents; };
      # User-facing top-level FHS-ish layout: /bin, /lib, /share, etc.,
      # produced as a symlinkJoin of every contents entry. Mirrors what
      # dockerTools' default `contents` staging does when contents is a flat
      # list of packages: e.g. /lib/python3.13/site-packages/AminoExtract is a
      # symlink into the aminoextract store path so Python finds it on the
      # default sys.path without needing PYTHONPATH gymnastics.
      #
      # buildEnv is built from the original (untrimmed) contents on purpose:
      # we then `cp -a` its tree into trimmedRoot's $out, and the trimmedRoot
      # derivation discards references (see unsafeDiscardReferences below),
      # so the binEnv's closure does NOT propagate as a runtime dep.
      binEnv = pkgs.buildEnv {
        name = "viro-${name}-link-env";
        paths = contents;
        # ignoreCollisions: bash + bashInteractive both ship `bin/sh`, etc.
        # First-wins semantics match what the previous flat-contents staging
        # gave the pre-trim Docker images.
        ignoreCollisions = true;
      };
    in
    pkgs.stdenvNoCC.mkDerivation {
      name = "viro-${name}-trimmed-rootfs";
      __structuredAttrs = true;
      # See comment above. References to original store paths are
      # baked into the rootfs but are intentionally not propagated as
      # runtime deps of this derivation. Requires __structuredAttrs.
      unsafeDiscardReferences.out = true;
      nativeBuildInputs = [ pkgs.coreutils ];
      dontUnpack = true;
      dontConfigure = true;
      dontBuild = true;
      dontFixup = true;
      inherit closureInfo binEnv;
      installPhase = ''
        set -eu
        mkdir -p "$out/nix/store"
        mkdir -p "$out/etc"
        mkdir -p "$out/tmp"
        chmod 1777 "$out/tmp"

        # /etc/passwd + /etc/group with appuser:10001 to match conda images.
        {
          echo 'root:x:0:0:root:/root:/bin/bash'
          echo 'appuser:x:10001:10001:appuser:/nonexistent:/sbin/nologin'
        } > "$out/etc/passwd"
        {
          echo 'root:x:0:'
          echo 'appuser:x:10001:'
        } > "$out/etc/group"

        # Copy each path in the recursive closure into rootfs/nix/store/.
        # cp -a preserves intra-closure symlinks (common in python envs).
        # --reflink=auto is a btrfs/xfs optimisation; falls back to a real
        # copy on other filesystems (notably the build sandbox tmpfs).
        while IFS= read -r p; do
          [ -n "$p" ] || continue
          cp -a --reflink=auto "$p" "$out/nix/store/"
        done < "$closureInfo/store-paths"

        # FHS layout (/bin, /lib, /share, ...) overlaid from buildEnv. Its
        # tree is all symlinks pointing into /nix/store/...; cp -a preserves
        # the symlinks. Targets resolve against the closure paths we just
        # copied above. Use `cp -a $binEnv/. $out/` to merge contents-of
        # rather than nest the env dir at $out/binEnv/.
        cp -a "$binEnv/." "$out/"
        # buildEnv leaves a $out/nix-support/ directory we don't need in
        # the image; it's just buildEnv's propagated-build-inputs marker.
        rm -rf "$out/nix-support"

        ${cleanupScript}
      '';
    };
in
{
  inherit mkTrimmedRoot;
}
