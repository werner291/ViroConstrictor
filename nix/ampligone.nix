{ lib
, stdenv
, fetchFromGitHub
, fetchurl
, python3Packages
, autoreconfHook
, zlib
}:

let
  # parasail C library — the parasail-python package's setup.py would
  # otherwise download this from GitHub at build time, which doesn't work
  # in the Nix sandbox. We build it separately and inject the .so into
  # the python package directory.
  parasail-c = stdenv.mkDerivation rec {
    pname = "parasail-c";
    version = "2.6.2";
    src = fetchFromGitHub {
      owner = "jeffdaily";
      repo = "parasail";
      rev = "v${version}";
      sha256 = "0pnw8x266b4qggv9hn4sng9z6zcq0rg7h6slcq3ka3snybzn61r8";
    };
    nativeBuildInputs = [ autoreconfHook ];
    # Disable AVX-512 etc. detection issues; default configure works on x86_64.
    enableParallelBuilding = true;
  };

  # Pure-python helpers not in nixpkgs.
  parmap = python3Packages.buildPythonPackage rec {
    pname = "parmap";
    version = "1.7.0";
    pyproject = true;
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/source/p/parmap/parmap-${version}.tar.gz";
      sha256 = "0yzlqfnkl34s7z03wkkdc2y8nf8y26lf6q9x0x70hg3wc4855i3p";
    };
    build-system = [ python3Packages.hatchling ];
    doCheck = false;
  };

  pgzip = python3Packages.buildPythonPackage rec {
    pname = "pgzip";
    version = "0.3.4";
    pyproject = true;
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/source/p/pgzip/pgzip-${version}.tar.gz";
      sha256 = "10648bw5yyc6nagmm66k8psfxaiz3sqnpzj6iraqhvmw76848mpg";
    };
    build-system = [ python3Packages.setuptools ];
    doCheck = false;
  };

  # mappy: minimap2 python bindings. Builds a C extension; needs zlib.
  mappy = python3Packages.buildPythonPackage rec {
    pname = "mappy";
    version = "2.28";
    pyproject = true;
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/source/m/mappy/mappy-${version}.tar.gz";
      sha256 = "1fyfhia08j3v9y6w26hnd3581qbnc7i1b0h2ara8yrmxc9fpmgqf";
    };
    build-system = with python3Packages; [ setuptools cython ];
    buildInputs = [ zlib ];
    doCheck = false;
  };

  parasail-python = python3Packages.buildPythonPackage rec {
    pname = "parasail";
    version = "1.3.4";
    format = "setuptools";
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/source/p/parasail/parasail-${version}.tar.gz";
      sha256 = "03qvnswvzv6pv5lzlnd05rbjphhl29qiasbyvnpmmvz3z9fh79yn";
    };
    # Skip the C library bundle download/build; we provide it via parasail-c.
    PARASAIL_SKIP_BUILD = "1";
    propagatedBuildInputs = with python3Packages; [ numpy ];
    # Drop libparasail.so into the package directory so the runtime loader
    # in parasail/__init__.py finds it without LD_LIBRARY_PATH gymnastics.
    postInstall = ''
      pkgdir=$(find $out -name parasail -type d | head -n1)
      cp ${parasail-c}/lib/libparasail${stdenv.hostPlatform.extensions.sharedLibrary} \
        "$pkgdir/"
    '';
    doCheck = false;
  };
in
python3Packages.buildPythonApplication rec {
  pname = "ampligone";
  version = "2.0.2";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "RIVM-bioinformatics";
    repo = "AmpliGone";
    rev = "v${version}";
    sha256 = "15n4n6d2aa2vj17c34d1av93rzq7gnk8bd4aqqja6hg2b07nd35i";
  };

  # Upstream pins exact versions of pandas/pysam/biopython/etc that don't
  # match what nixpkgs ships. Loosen the pins.
  postPatch = ''
    substituteInPlace pyproject.toml \
      --replace 'pysam==0.22.*' 'pysam' \
      --replace 'pandas==2.2.*' 'pandas' \
      --replace 'mappy==2.28' 'mappy' \
      --replace 'biopython==1.84' 'biopython' \
      --replace 'parmap==1.7.*' 'parmap' \
      --replace 'parasail==1.3.4' 'parasail' \
      --replace 'rich==13.7.*' 'rich' \
      --replace 'pgzip==0.3.4' 'pgzip'
  '';

  build-system = [ python3Packages.hatchling ];

  dependencies = with python3Packages; [
    pysam
    pandas
    biopython
    rich
    mappy
    parmap
    parasail-python
    pgzip
  ];

  doCheck = false;

  pythonImportsCheck = [ "AmpliGone" ];

  meta = with lib; {
    description = "Removes primer sequences from FastQ NGS reads in amplicon sequencing experiments";
    homepage = "https://github.com/RIVM-bioinformatics/AmpliGone";
    license = licenses.agpl3Only;
    mainProgram = "ampligone";
  };
}
