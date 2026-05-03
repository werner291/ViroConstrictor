# nix/ — experimental container build for ViroConstrictor

Builds all six ViroConstrictor containers (Alignment, Clean, ORF_analysis, core_scripts, mr_scripts, Consensus) as both Docker / OCI tarballs and Singularity `.sif` files directly from nix — no `dockerfile → docker build → .tar → apptainer build` pipeline. The flake at the repo root is a thin (~50 line) wiring layer; this directory holds everything substantive: per-container closures, slim overrides, RIVM derivations, smoke tests, and this write-up.

An **initial proposal**, not a merge request, and not yet ready for one. Filed in response to issue 161 (containers too big), to see whether the maintainers are interested in pursuing this direction at all. The containers all build, and a smoke test per container passes (`nix flake check`). Production acceptance would need stronger tests on top — the snakemake e2e suite (`tests/e2e/test_e2e.py`) running against the nix images, real apptainer execution on an HPC node, and CI wiring. None of that is in scope here.

Nothing in the existing build pipeline (`containers/*.dockerfile`, `containers/build_containers.py`, the snakemake rules) is changed by this directory's presence — it's strictly opt-in.

## Quick start

```sh
nix flake check                     # builds and smoke-tests every container
```

Per-container Docker / OCI tarballs — pipe the result into `docker load`:

```sh
nix build .#alignment-docker     && ./result | docker load
nix build .#clean-docker         && ./result | docker load
nix build .#orf-analysis-docker  && ./result | docker load
nix build .#core-scripts-docker  && ./result | docker load
nix build .#mr-scripts-docker    && ./result | docker load
nix build .#consensus-docker     && ./result | docker load
```

Per-container Singularity `.sif` files — `result` is the `.sif` directly:

```sh
nix build .#alignment-sif
nix build .#clean-sif
nix build .#orf-analysis-sif
nix build .#core-scripts-sif
nix build .#mr-scripts-sif
nix build .#consensus-sif
```

Convenience apps that build + load a docker image in one step:

```sh
nix run .#load-alignment
nix run .#load-clean
nix run .#load-orf-analysis
nix run .#load-core-scripts
nix run .#load-mr-scripts
nix run .#load-consensus
```

The header of `flake.nix` documents every target.

## Sizes

Streamed docker tarball bytes (the actual loadable image size); `.sif` is squashfs file size where measured. Pinned to `flake.lock` (nixos-unstable rev `15f4ee45`).

| Container    | Dockerfile baseline (`main`) | nix docker | nix sif |
|---|---|---|---|
| Alignment    | 1.19 GB | **235 MB**  | 96 MB  |
| Clean        | 2.83 GB | **1435 MB** | 447 MB |
| ORF_analysis | 786 MB  | **625 MB**  | 204 MB |
| core_scripts | 1.38 GB | **1010 MB** | 351 MB |
| mr_scripts   | 802 MB  | **649 MB**  | 215 MB |
| Consensus    | does not build cleanly on `main` today | **650 MB** | 215 MB |

Alignment is the cleanest case (80% off baseline). Clean and core_scripts came in *bigger* than baseline on first nix attempt (3.18 GB and 1.52 GB respectively) before three overrides under `nix/` brought them in line — see "Counter-crime" below.

Baseline sizes captured separately from a clean build of upstream `main` at `199814b` against `mambaorg/micromamba@sha256:313021a5...` (notes at `~/workspace/bio-contrib/161-container-sizes.md`).

## Smoke tests

`nix flake check` runs one test per container in nix's hermetic build sandbox (no docker daemon, no apptainer install, no network at check time). Each exercises real tools end-to-end on real fixtures, not `--version` calls:

| Container | What the smoke test does |
|---|---|
| Alignment    | `minimap2 -ax sr ref.fa reads.fq \| samtools sort` → assert ≥1 mapped read |
| Clean        | fastp → minimap2/samtools → bedtools genomecov → fastqc HTML report → multiqc against fastqc output → ampligone --help |
| ORF_analysis | prodigal predicts ORFs → aminoextract extracts proteins from features.gff |
| core_scripts | python: `import pysam, Bio, AminoExtract`; pysam reads BAM; biopython parses FASTA |
| mr_scripts   | same python smoke (smaller closure, no fastqc) |
| Consensus    | trueconsense produces a real consensus FASTA from a sorted+indexed BAM |

Test fixtures (reference genome, primers, GFF) are fetched via `pkgs.fetchurl` from this repo at a pinned commit. Synthetic FASTQ is generated at check time by sliding a window over the reference; one shared pre-built BAM is reused by tests in containers that don't ship samtools/minimap2.

## VM-level integration tests (`nix/vm-tests.nix`)

A second layer of tests boots a NixOS VM per container and runs the **same script body** the closure-level test runs — but inside the actual built image, executed by an actual container runtime. This catches hazards the closure-level tests can't see: missing rootfs bits, broken `/nix/store` layout under the chosen runtime, lazy `dlopen` of a stripped lib, Python lazy-imports that only fire on real input, and (critically) drift between container-runtime forks.

For each container, **three runtimes** are exercised inside one VM:

| Runtime | nixpkgs attr | Why |
|---|---|---|
| Docker     | `pkgs.docker`     | OCI tarball loaded with `docker load`, run with `docker run --rm`. |
| Apptainer  | `pkgs.apptainer`  | Linux Foundation fork. `.sif` executed with `apptainer exec`. |
| SingularityCE | `pkgs.singularity` | Sylabs fork. **Same `.sif`**, executed with `singularity exec`. |

The Apptainer + SingularityCE pairing is deliberate, not duplication: the two forks diverged in 2021 and have drifted on userns defaults, fakeroot handling, OCI integration, and bind-mount semantics. Many HPC sites run one fork or the other; verifying that the same `.sif` runs cleanly under both meaningfully extends "different cluster, different runtime" coverage. The only reason both forks coexist in one VM module is that they conflict on the `singularity` symlink, so SingularityCE is invoked by absolute store path and not put on `PATH`. See the header of `nix/vm-tests.nix` for the gory details.

Wired into `flake.nix` as `checks.${system}.vm-<container>`, alongside the closure-level checks. Each VM check runs the three runtimes as named subtests, so failure output identifies exactly which runtime broke without paying the VM-startup cost three times.

```sh
nix flake check                          # everything: closure + VM tests
nix build .#checks.x86_64-linux.vm-alignment    # one VM test
```

**KVM required.** `pkgs.testers.nixosTest` boots qemu with `-enable-kvm`; `/dev/kvm` must be accessible. CI runners need a kvm-enabled executor — there is no nested-virt-free path. Validated locally on the alignment container: docker, apptainer, and singularity-CE all run the smoke script end-to-end (`mapped reads: 397` from each).

### aarch64-via-binfmt smoke test (`nix/vm-tests-aarch64.nix`)

Capability demo: build the alignment container as an aarch64-linux image on an x86_64 host, then run its smoke test inside a NixOS VM that registers binfmt_misc + qemu-user emulation for aarch64. The host is x86_64, no aarch64 hardware is involved, and the resulting container's binaries are real aarch64 ELF (verified by `file`); they execute under qemu-aarch64 user-mode the kernel routes them through.

Wired into the flake as:

```sh
nix build .#alignment-docker-aarch64-linux       # cross-built aarch64 OCI tarball
nix build .#checks.x86_64-linux.vm-alignment-aarch64 -L
```

What's covered: alignment only (minimap2 + samtools + bedtools, all cross-build clean from nixpkgs at the pinned revision). Docker and apptainer both run the smoke script under emulation; the script reports `mapped reads: 397`, identical to the x86_64 path. SingularityCE is dropped from the aarch64 variant (the setuid + namespace flow interacts poorly with binfmt-preloaded interpreters; rationale in the file header).

What is **not** covered, by container, all due to upstream nixpkgs blockers — these are the project's pinned-nixpkgs reality, not a flake limitation. They are individually fixable with overlays + upstream PRs, but out of scope for a capability demo:

- **Clean**: `fastp` ships AVX2-only x86 SIMD code with no aarch64 fallback, marked `meta.platforms = x86`. Also `polars` (a transitive in the multiqc closure) carries `meta.broken = true on aarch64-linux` in the pinned nixpkgs.
- **ORF_analysis, core_scripts, mr_scripts, Consensus**: depend on `aminoextract` and/or `ampligone`, whose Python C-extensions (and ampligone's bundled `parasail-c`) cross-build fragility under `pkgsCross.aarch64-multiplatform` is its own multi-day project. trueconsense additionally pulls in pysam-via-htslib whose cross-build needed an overlay fix even for alignment (see `nix/overlay.nix`).

Cross-build path used: `pkgs.pkgsCross.aarch64-multiplatform`. The host stays x86_64; only the produced binaries are aarch64. This avoids needing host-level binfmt to *build*; emulation is only needed to *run*. Two small overlays in `nix/overlay.nix` work around htslib's and samtools' Makefiles invoking bare `ar`/`ranlib` instead of `$(AR)`/`$(RANLIB)` — these would fail in any aarch64 cross-build of these tools, not just ours, and patches upstream are obvious.

VM module: `boot.binfmt.preferStaticEmulators = true` is the load-bearing knob. Without it, NixOS picks `qemu-aarch64-binfmt-P` (a dynamically-linked wrapper) as the binfmt interpreter, which fails inside Docker namespaces because its dynamic deps aren't visible to the container. `preferStaticEmulators = true` selects the static qemu from `pkgs.pkgsStatic.qemu-user`, with the `F` flag set on the binfmt registration so the kernel preloads the interpreter and it survives the namespace transition. Empirically required to make `docker run aarch64-image` Just Work; see the file header for the failure modes we hit before getting there.

Punchline: the host is x86_64. No aarch64 hardware involved.

What was **not** tested at either layer: the full snakemake e2e suite (`tests/e2e/test_e2e.py`) — the smoke tests verify tools work in isolation, not that the workflow assembles end-to-end. Wiring an e2e check would be the natural next step (a `nixosTest` running the full snakemake workflow against the apptainer images), but it's a much bigger commitment.

### Per-CPU-baseline Clean variants (`nix/polars-variants.nix`)

Capability demo on the orthogonal axis to aarch64: per-microarchitecture (compat / 32 / 64), not per-architecture. Same flake, same expressions, just a different parameter mapped over the same builder.

Upstream py-polars publishes three runtime sub-packages, each a separate maturin-built wheel:

- `_polars_runtime_compat` (~ x86-64-v2 baseline)
- `_polars_runtime_32` (~ x86-64-v3 / AVX2; what nixpkgs builds by default)
- `_polars_runtime_64` (~ x86-64-v4 / AVX-512)

At `import polars`, `polars/_plr.py` dispatches via cpuid and tries variants in order; the first one that imports cleanly wins, missing variants fall through silently. So an image with exactly one variant installed works on any host whose CPU implements at least that variant's feature flags.

The conda Clean container ships **`compat` and `32` only**, dispatched at runtime from a single image. The Nix demo flips that around: one image per variant, each shipping exactly the matching `_polars_runtime_<v>` directory and nothing else. Selecting at image-pull time instead of import-time is a deliberately different tradeoff — smaller closures per image, no bundled dispatch path. We omit `64` here for parity with conda; the override would build it just fine, see `nix/polars-variants.nix`.

Wired as:

```sh
nix build .#clean-compat-docker -L          # ~5-15 min on cold cache (rebuilds polars rust crate)
nix build .#clean-32-docker -L              # free (variant 32 is the nixpkgs default; cached)
nix build .#checks.x86_64-linux.vm-clean-32 # full Clean smoke + per-variant assertion
```

How it works: nixpkgs `python3Packages.polars` hard-codes one runtime manifest:

```nix
maturinBuildFlags = [ "-m" "py-polars/runtime/polars-runtime-32/Cargo.toml" ];
```

`nix/polars-variants.nix` exports a 10-line `mkPolarsVariant` that overrides exactly that flag and points at the matching `polars-runtime-${variant}/Cargo.toml`. `nix/clean-builder.nix` then rebuilds `multiqc-slim` against the variant polars (multiqc is the only Clean dependency that touches polars) and assembles the same closure `containers.clean` ships, plus polars on the user-facing python so the in-container assertion can do `import polars` directly.

The pitch: in conda, shipping per-variant Clean containers would mean patched bioconda recipes per variant, separate channels, separate hashes, separate CI. In Nix it's one override expression and a list to map it over (`cleanVariantNames = [ "compat" "32" ];` in `flake.nix`). Per-architecture (aarch64 via cross-build, above) and per-microarchitecture (compat/32/64 via maturin override, here) come from the same flake using the same parameterise-and-map pattern; the only difference is which axis you parameterise.

Per-variant VM checks (`vm-clean-${variant}`) load each variant's docker image and `.sif`, run the Clean smoke (fastp + minimap2 + samtools + bedtools + fastqc + multiqc + ampligone), then assert exactly one `_polars_runtime_<v>` directory in site-packages, none of the others, plus `polars.DataFrame({"a":[1,2,3]}).sum()` returns 6 (the load-bearing test that polars's cpuid dispatch found the kept variant; if the wrong manifest were built or none were importable, this would crash with illegal-instruction or `ImportError`).

Image-size delta vs the unparameterised `clean-docker`: ~1.4 GB streamed tarball in both cases, differing by hundreds of bytes (just the metadata referencing one variant manifest vs. another). Same one polars variant ships in either; the demo just selects it explicitly via the override instead of inheriting nixpkgs' default.

Not covered here, deferred:

- **OpenBLAS, parasail per-march**: these tools' multi-version dispatch lives inside a single `.so` (function-multiversioning, runtime-resolved at first call). There's no file-level split to strip, so the per-image-variant pattern doesn't apply; they'd need either a per-image source rebuild with `-march=` baked in, or accepting their bundled fat-binary path.

## What's verified vs what isn't

Verified: every container builds, every smoke test passes — see the table above. Each smoke test exercises the tools end-to-end on real fixtures, not just `--version`.

Not verified (because the snakemake workflow itself wasn't run against the nix images — that's the natural next step but a much bigger commitment): whether anything in the *full* pipeline depends on something only present in the conda images. Plausibly-affected items to check, ranked roughly by likelihood:

- **Tool version drift, in both directions.** For 4 of 5 spot-checked tools the nix containers ship a *newer* version than what `workflow/envs/*.yaml` pins: minimap2 2.30 vs 2.28 (your pin is from March 2024), samtools 1.22.1 vs 1.21, fastp 1.1.0 vs 1.0.1, biopython 1.86 vs 1.84. The one tool nixpkgs is genuinely behind on is multiqc (1.30 vs your 1.32, ~2 minor versions). If any rule parses tool output by exact version, it'd notice the move in either direction. Fixable with overlays pinning to the env yaml versions exactly.
- **Python version**: Clean.yaml pins `python=3.12`, the three script envs (ORF_analysis, core_scripts, mr_scripts) pin `python=3.10`, Alignment pins `python=3.12`. nixpkgs at the pinned rev dropped 3.10, so all containers ship the nixpkgs default (3.13). We picked 3.13 because workflow correctness here depends on package compatibility (biopython, pandas, pysam — all of which support 3.13) far more than CPython patch release. Real risk is some rule importing a 3.10-only stdlib alias.
- **`paftools.js`** (minimap2's optional companion script) needs the `k8` v8 JS engine, which isn't in nixpkgs. If any rule calls it, the Alignment image fails. *Checked: `grep -r paftools ViroConstrictor/workflow/` — 0 matches today.* Fix-if-needed: small `k8` derivation.
- **`mappy`** (Python binding for minimap2, ≠ the CLI) is in `Clean.yaml` but not in nixpkgs. *Checked: `grep -rE 'import mappy|from mappy' ViroConstrictor/workflow/` — 0 matches today.* Fix-if-needed: inline derivation similar to the ones in `nix/ampligone.nix`.
- **`/etc/passwd` is minimal**: no `appuser`. Probably harmless under apptainer (which maps the host user). *Checked: no rule references `appuser` or UID `10001` — 0 matches.*

A separate finding worth flagging — this is a problem with the *existing* pipeline, not with this proposal:

- **`containers/Consensus.dockerfile` does not build cleanly on `main` today.** `docker build --no-cache --pull -f containers/Consensus.dockerfile` fails inside the `pip install git+...TrueConsense` step with `gcc: No such file or directory` while compiling biopython from source. Reproducible. The published `.sif` works only because `containers/build_containers.py:51-52` skips builds when the container hash is already in the upstream registry — so the breakage is hidden until the next env hash change. The nix build sidesteps this entirely (biopython comes from nixpkgs pre-built, no pip-from-source compile).

## RIVM-internal Python tooling

Three tools aren't in nixpkgs and have small custom derivations:

| File | Tool | Used by |
|---|---|---|
| `nix/aminoextract.nix`  | aminoextract  | ORF_analysis, core_scripts, mr_scripts, Consensus |
| `nix/ampligone.nix`     | ampligone     | Clean |
| `nix/trueconsense.nix`  | TrueConsense  | Consensus |

Each is a `buildPythonApplication` pinned to its current upstream tag. Notable gotchas documented inline — chiefly: aminoextract's `python-magic` ctypes-loads `libmagic` (needs an `LD_LIBRARY_PATH` wrapper); ampligone has four Python deps missing from nixpkgs and ships a bundled `parasail-c` whose `setup.py` would otherwise hit the network mid-build; TrueConsense pins exact versions of its deps that have to be relaxed to nixpkgs versions.

## What nix actually buys you here

**The size numbers are not the interesting part.** A separate experiment on `experiment/161-container-slimming` slimmed the existing dockerfiles by hand (apt-get cleanup, `--no-install-recommends`, drop unused build helpers, prune `__pycache__`) and got:

| Container | Dockerfile baseline | Hand-slimmed Dockerfile | Saved |
|---|---|---|---|
| Alignment    | 1.19 GB | 867 MB | -29% |
| Clean        | 2.83 GB | 2.39 GB | -16% |
| ORF_analysis | 786 MB  | 439 MB | -44% |
| core_scripts | 1.38 GB | 949 MB | -33% |
| mr_scripts   | 802 MB  | 458 MB | -43% |
| **Total (5)** | **6.99 GB** | **5.10 GB** | **-27%** |

So you can get most of the size win with conventional Docker tactics. nix lands roughly where careful Docker tuning would land after substantial effort.

### The honest "yeah, you can do that without nix"

Each property below is individually achievable with tools you already use or could add. The argument for nix isn't that it does anything uniquely — it's that you get the *bundle*, default-on, without the integration tax of wiring 4-5 separate tools that each need their own maintenance.

| Property | What this proposal delivers | Equivalent without nix |
|---|---|---|
| Transitive dep pinning | `flake.lock` auto-generated on first build; every direct + transitive package frozen at one nixpkgs revision | `conda-lock` or `micromamba env export --explicit` per env, captured + checked in + regenerated on every dep change |
| Surgical upstream patching | `pkgs.<tool>.override { ... }` in 20 lines, no fork | Private bioconda channel for the patched tool, or vendor + maintain a fork |
| Cross-image dep dedup | Each `/nix/store/<hash>` becomes its own image layer automatically; six containers share one biopython, one pysam, one Python | Manually curated multi-stage `Dockerfile` with shared base images, kept in sync as deps move |
| Hermetic tests | `nix flake check` is sandboxed and parallel; `nix log <drv>` for failures; anyone with nix verifies every claim here in one command | Custom CI scripts running tests inside throwaway containers, plus glue to surface failures |
| Compact image format | Same closure → docker tarball *and* squashfs `.sif` directly, no `docker → tar → apptainer build` chain | Existing `convert_artifact_containers_for_apptainer.py`; works, but a step you have to maintain |

The version-skew side: today the env yaml pins ~10 of (in Clean's case) 183 transitive packages. The other 173 are whatever bioconda's solver feels like resolving on the day of the build — that's why `pkg_resources` quietly disappeared from the baseline images (setuptools 82+ stopped shipping it; nothing in the yaml said "setuptools < 82") and why `containers/Consensus.dockerfile` has been silently broken since whatever transitive-set bumped under it. The build skip-if-hash-known logic in `containers/build_containers.py:51-52` is what's currently masking the breakage. **This is fixable in conda** — `conda-lock` is exactly the right tool — but it's not what the project does today.

### Three nixpkgs-side packaging crimes that had to be countered

(without these overrides, Clean came out at 3.18 GB on first nix attempt — *worse* than the conda baseline.)

- multiqc declaring `boto3` + `pyarrow` + `kaleido` + `tiktoken` as *required* deps for opt-in features (~1.5 GB) → `nix/multiqc-slim.nix`
- nixpkgs' fastqc bundling a 907 MB JDK with no slim "AWT yes, IDE chromium no" middle option → `nix/fastqc-slim.nix` (custom 57 MB JRE via `jlink` over only the 4 modules FastQC actually uses)
- jlink baking source-JDK paths into output binaries, which nix sees as runtime refs and pulls the source JDK back into the closure unless you scrub them → `remove-references-to` + `disallowedReferences = [ openjdk21 ]` as the safety net

The smoke tests caught real over-trims within one iteration each (polars and spectra both turn out to be load-time imports in multiqc, even though they look optional from the dep declaration). The override + verify cycle is what's actually new here, not the resulting size.

### Caveats

- **Flakes are still officially experimental** — usage requires `--extra-experimental-features 'nix-command flakes'` or a line in `~/.config/nix/nix.conf`. Despite this every modern nix project uses them and nixpkgs itself is a flake; they're not going anywhere, but the "experimental" label is real.
- **`nixos-unstable` is what's pinned.** Gets a CI burn-in before each tag, but the channel name is a word you may have to defend. One-line switch to a release channel (`nixos-25.05`) if needed.
- **Maintenance: package upgrades become a deliberate `nix flake update` action**, not solver drift between rebuilds. Five override / derivation files in `nix/` need touching when their underlying upstreams move; failures surface in `nix flake check`, not at workflow runtime.

## What this does not do

- Replace conda envs (`repro_method = conda` still consults `workflow/envs/*.yaml`).
- Migrate the project to nix; existing dockerfiles untouched.
- Plug into existing CI; same artifact formats, but no wiring included.
- Replace `tests/e2e/test_e2e.py`.
