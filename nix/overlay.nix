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

      # Snakemake's SLURM executor stack. Not in nixpkgs; needed only by
      # the multi-node SLURM VM test (nix/vm-test-pipeline-slurm.nix).
      # Local-execution paths don't import these.
      snakemake-executor-plugin-slurm-jobstep =
        pyfinal.callPackage ./snakemake-executor-plugin-slurm-jobstep.nix { };
      snakemake-executor-plugin-slurm =
        pyfinal.callPackage ./snakemake-executor-plugin-slurm.nix { };

      # Pin snakemake to 9.5.0 (the version ViroConstrictor's June-2025
      # snakemake-9 compat refactor was tested against). nixpkgs ships
      # 9.16.3, which has refactored away `snakemake.logging.logger_manager`
      # and `snakemake.resources.DefaultResources`; chasing each API drift
      # is whack-a-mole. Pin once.
      # snakemake-interface-logger-plugins: nixpkgs ships 2.0.1, but
      # ViroConstrictor's in-repo `snakemake_logger_plugin_viroconstrictor`
      # subclasses the 1.x `LogHandler` ABC (no `emit` abstract method).
      # The 2.x ABC adds `emit`, so the plugin can't be instantiated against
      # 2.x. Pin to the latest 1.x release.
      snakemake-interface-logger-plugins = pyprev.snakemake-interface-logger-plugins.overridePythonAttrs (old: rec {
        version = "1.2.4";
        src = pyfinal.fetchPypi {
          pname = "snakemake_interface_logger_plugins";
          inherit version;
          hash = "sha256-CRk7B8Jgs+/IinWg0zdnggcF9m6FwU1PDQ5WKxI8PFg=";
        };
      });

      snakemake = pyprev.snakemake.overridePythonAttrs (old: rec {
        version = "9.5.0";
        src = pyfinal.fetchPypi {
          inherit (old) pname;
          inherit version;
          hash = "sha256-VvomUQCHKQFyu2eA2sDPhgh1ohXScHiQt+irpnlRTQk=";
        };
        # 9.5.0 caps pulp <3.2; nixpkgs ships pulp 3.3. Bump is minor.
        pythonRelaxDeps = (old.pythonRelaxDeps or [ ]) ++ [ "pulp" ];
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
