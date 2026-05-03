{ lib
, python3Packages
, fetchFromGitHub
, aminoextract ? null
}:

python3Packages.buildPythonApplication rec {
  pname = "trueconsense";
  version = "0.5.2";
  format = "pyproject";

  src = fetchFromGitHub {
    owner = "RIVM-bioinformatics";
    repo = "TrueConsense";
    rev = "v${version}";
    hash = "sha256-em405efYtOlDpELcwfJ/Qe5LJp6QRMGgyiGuCj0KR7o=";
  };

  # Upstream pins exact dep versions in pyproject.toml. Loosen them so the
  # nixpkgs-provided versions of pysam/pandas/biopython/tqdm are accepted, and
  # drop the aminoextract pin when no aminoextract package is provided
  # (TrueConsense never imports it; it is only listed as a co-installed env dep).
  postPatch = ''
    substituteInPlace pyproject.toml \
      --replace '"pysam==0.23.3"'    '"pysam"' \
      --replace '"pandas==2.3.*"'    '"pandas"' \
      --replace '"tqdm==4.59.0"'     '"tqdm"' \
      --replace '"biopython==1.85"'  '"biopython"'
  '' + lib.optionalString (aminoextract == null) ''
    substituteInPlace pyproject.toml \
      --replace '"aminoextract==0.4.1"' ""
  '' + lib.optionalString (aminoextract != null) ''
    substituteInPlace pyproject.toml \
      --replace '"aminoextract==0.4.1"' '"aminoextract"'
  '';

  nativeBuildInputs = [ python3Packages.hatchling ];

  propagatedBuildInputs = with python3Packages; [
    pysam
    pandas
    tqdm
    biopython
  ] ++ lib.optional (aminoextract != null) aminoextract;

  # Upstream ships tests but they need real BAM/GFF fixtures and pytest plugins
  # that are not configured here; smoke-test via --help instead.
  doCheck = false;

  pythonImportsCheck = [ "TrueConsense" ];

  meta = with lib; {
    description = "Nucleotide consensus caller for viral sequencing data that uses GFF data to improve accuracy";
    homepage = "https://github.com/RIVM-bioinformatics/TrueConsense";
    license = licenses.agpl3Only;
    mainProgram = "trueconsense";
    platforms = platforms.unix;
  };
}
