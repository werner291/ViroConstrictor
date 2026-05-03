# Build a docker (streamLayeredImage) and a singularity (.sif) output from
# the same closure. dockerTools.streamLayeredImage emits a script that
# streams the OCI tarball to stdout, so loading is `./result | docker load`
# with no docker daemon needed at build time. singularity-tools.buildImage
# produces the `.sif` directly — no docker → tar → apptainer conversion.
pkgs:

let
  # /tmp with sticky bit, /etc/passwd and /etc/group entries for appuser.
  # Matches the existing conda containers' UID/GID 10001 so bind-mounted
  # output files end up owned by the same user across both image families.
  # Some tools (mamba/conda, certain python libs) refuse to run as root or
  # complain about a missing /etc/passwd entry; this prevents both.
  rootfsExtras = pkgs.runCommand "rootfs-extras" { } ''
    mkdir -p $out/tmp && chmod 1777 $out/tmp
    mkdir -p $out/etc
    {
      echo 'root:x:0:0:root:/root:/bin/bash'
      echo 'appuser:x:10001:10001:appuser:/nonexistent:/sbin/nologin'
    } > $out/etc/passwd
    {
      echo 'root:x:0:'
      echo 'appuser:x:10001:'
    } > $out/etc/group
  '';
in
{
  mkDocker = name: closure: pkgs.dockerTools.streamLayeredImage {
    name = "viro-${name}-nix";
    tag = "demo";
    contents = closure ++ [ rootfsExtras ];
    config = {
      Cmd = [ "${pkgs.bashInteractive}/bin/bash" ];
      Env = [ "PATH=/bin:/usr/bin" ];
      # Match the conda containers (`USER appuser` with UID 10001) so
      # bind-mounted output files end up owned by the same UID across both
      # image families. A drop-in replacement for the conda containers
      # should not silently change file ownership semantics on the host.
      User = "10001:10001";
    };
  };

  # Note: singularity .sif files don't carry a baked-in default user the
  # way docker does. apptainer/singularity always run as the invoking host
  # user (unless `--fakeroot` or setuid is in play). Adding `User = ...` to
  # singularity-tools.buildImage would be a no-op; documenting that here
  # rather than trying to set it.
  mkSif = name: closure: pkgs.singularity-tools.buildImage {
    name = "viro-${name}-nix";
    contents = closure;
    diskSize = 6144;   # uncompressed Clean closure ~3 GB
    memSize = 2048;
  };
}
