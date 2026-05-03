# RIVM tools not in nixpkgs + slim overrides for nixpkgs packages whose
# default closures pull in much more than this project needs. See
# nix/README.md and the per-file headers for rationale.
self: super: {
  # aminoextract is now a buildPythonPackage (see nix/aminoextract.nix), so
  # it lives inside the python package set: that's how `python.withPackages`
  # finds it for the core-scripts / mr-scripts envs that need to `import
  # AminoExtract`.
  #
  # Done via `python3.override { packageOverrides = ...; }` rather than
  # `python3Packages.overrideScope`: the latter overrides the top-level
  # `pkgs.python3Packages` attribute but does NOT rethread into
  # `pkgs.python3.pkgs`, so `pkgs.python3.withPackages (ps: [ ps.aminoextract ])`
  # would still see the unmodified scope. The override-on-the-interpreter
  # pattern propagates through both attributes.
  python3 = super.python3.override (old: {
    packageOverrides = pyfinal: pyprev: (old.packageOverrides or (_: _: { })) pyfinal pyprev // {
      aminoextract = pyfinal.callPackage ./aminoextract.nix { };
    };
  });
  python3Packages = self.python3.pkgs;
  aminoextract = self.python3Packages.aminoextract;

  ampligone    = self.callPackage ./ampligone.nix    { };
  trueconsense = self.callPackage ./trueconsense.nix { };
  fastqc-slim  = self.callPackage ./fastqc-slim.nix  { };
  multiqc-slim = self.callPackage ./multiqc-slim.nix { };

  # Cross-build fix: htslib's `libhts.a` rule expands `$(AR)`, which GNU
  # make defaults to the bare string `ar` if nothing overrides it on the
  # make command line. (Environment AR is shadowed by make's internal
  # defaults unless `-e` or an explicit makefile assignment is in play,
  # neither of which applies here.) The nixpkgs htslib derivation passes
  # `AR=$AR` only on the static-build path, so the dynamic/static parallel
  # build under `pkgsCross.aarch64-multiplatform` invokes the bare `ar`,
  # which is not on PATH (cross binutils are exposed only under their
  # target-prefixed names). The link step fails: "ar: command not found".
  #
  # Inject AR + RANLIB on the make command line via makeFlagsArray, which
  # nixpkgs renders as positional `make AR=... RANLIB=...` arguments.
  # `stdenv.cc.bintools.targetPrefix` is empty for native builds, so this
  # is a no-op for the x86_64 native build.
  htslib = super.htslib.overrideAttrs (old: {
    preBuild = (old.preBuild or "") + ''
      makeFlagsArray+=( "AR=''${AR:-ar}" "RANLIB=''${RANLIB:-ranlib}" )
    '';
  });

  # Same `$(AR)`-defaults-to-bare-`ar` cross-build pitfall as htslib above,
  # in samtools' own `libst.a` rule (Makefile line 151). Same fix.
  samtools = super.samtools.overrideAttrs (old: {
    preBuild = (old.preBuild or "") + ''
      makeFlagsArray+=( "AR=''${AR:-ar}" "RANLIB=''${RANLIB:-ranlib}" )
    '';
  });
}
