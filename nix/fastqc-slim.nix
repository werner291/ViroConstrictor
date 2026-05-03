# FastQC overridden to use a custom 57 MB JRE built with `jlink`.
#
# Why: nixpkgs' default `fastqc` wraps with the full openjdk21 (~907 MB
# closure). FastQC actually needs only 4 of openjdk21's ~70 modules
# (java.base, java.desktop, java.scripting, java.sql — established via
# `jdeps --print-module-deps` over FastQC's jars). `jlink` builds a
# custom JRE with exactly those modules; java.desktop carries AWT, so
# FastQC's SVG plot rendering still works (which `jre_headless` would
# break).
#
# `disallowedReferences = [ openjdk21 ]` is the safety net: jlink bakes
# the source JDK path into libjava.so / jexec / jspawnhelper, which nix
# would otherwise resolve as a runtime reference and pull openjdk21
# back into the closure — defeating the whole exercise. We scrub those
# references with `remove-references-to`, and the disallowed-references
# check fails the build if any survive.
{ binutils
, fastqc
, openjdk21
, removeReferencesTo
, runCommand
}:

let
  fastqcJre = runCommand "fastqc-slim-jre" {
    nativeBuildInputs = [ binutils removeReferencesTo ];
    disallowedReferences = [ openjdk21 ];
  } ''
    ${openjdk21}/bin/jlink \
      --module-path ${openjdk21}/lib/openjdk/jmods \
      --add-modules java.base,java.desktop,java.scripting,java.sql \
      --strip-debug --no-man-pages --no-header-files \
      --compress=zip-9 \
      --output $out
    find $out -type f \( -name '*.so*' -o -executable \) \
      -exec remove-references-to -t ${openjdk21} {} +
  '';
in
fastqc.override { jre = fastqcJre; }
