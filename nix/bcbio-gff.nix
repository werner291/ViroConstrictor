# bcbio-gff: GFF parser used by ViroConstrictor.genbank for feature handling.
# Pulled from PyPI sdist; setuptools-based build.
{ lib, buildPythonPackage, fetchPypi, setuptools, biopython, six }:

buildPythonPackage rec {
  pname = "bcbio-gff";
  version = "0.7.1";
  pyproject = true;

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-0dwylBR7lbrO1gM/Y4ag/tRcQ3Z+8C0SI99e9JfpzKY=";
  };

  build-system = [ setuptools ];

  dependencies = [ biopython six ];

  pythonImportsCheck = [ "BCBio.GFF" ];

  meta = with lib; {
    description = "Read and write Generic Feature Format (GFF) with Biopython integration";
    homepage = "https://github.com/chapmanb/bcbb/tree/master/gff";
    license = licenses.mit;
  };
}
