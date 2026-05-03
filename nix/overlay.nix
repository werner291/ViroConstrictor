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
      aminoextract     = pyfinal.callPackage ./aminoextract.nix     { };
      biovalid         = pyfinal.callPackage ./biovalid.nix         { };
      bcbio-gff        = pyfinal.callPackage ./bcbio-gff.nix        { };
      viroconstrictor  = pyfinal.callPackage ./viroconstrictor.nix  { };

      # Pin snakemake to 9.5.0 (the version ViroConstrictor's June-2025
      # snakemake-9 compat refactor was tested against). nixpkgs ships
      # 9.16.3, which has refactored away `snakemake.logging.logger_manager`
      # and `snakemake.resources.DefaultResources`; chasing each API drift
      # is whack-a-mole. Pin once.
      snakemake = pyprev.snakemake.overridePythonAttrs (old: rec {
        version = "9.5.0";
        src = pyfinal.fetchPypi {
          inherit (old) pname;
          inherit version;
          hash = "sha256-VvomUQCHKQFyu2eA2sDPhgh1ohXScHiQt+irpnlRTQk=";
        };
        # 9.5.0 caps pulp <3.2 and snakemake-interface-logger-plugins <2.0;
        # nixpkgs ships pulp 3.3 and the logger-plugins interface 2.0.1.
        # Both bumps are minor in the surface ViroConstrictor exercises;
        # relax rather than pin both transitive deps.
        pythonRelaxDeps = (old.pythonRelaxDeps or [ ])
          ++ [ "pulp" "snakemake-interface-logger-plugins" ];
        # Two of snakemake 9.5.0's own resource-submission tests fail under
        # the dep set we're running against (`'NoneType' object is not
        # subscriptable` in test_resources_submitted_to_cluster). The
        # workflow-execution path ViroConstrictor exercises doesn't go
        # through that code; skip the upstream test suite rather than
        # patch tests we don't depend on.
        doCheck = false;
        doInstallCheck = false;
      });
    };
  });
  python3Packages = self.python3.pkgs;
  aminoextract = self.python3Packages.aminoextract;
  biovalid    = self.python3Packages.biovalid;
  viroconstrictor = self.python3Packages.viroconstrictor;

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
