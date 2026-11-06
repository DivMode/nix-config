{
  config,
  lib,
  local,
  pkgs,
  ...
}:
let
  cacheDirectory = local.cacheDirectory or null;
  enabled =
    pkgs.stdenv.hostPlatform.isDarwin && pkgs.stdenv.hostPlatform.isAarch64 && cacheDirectory != null;
  limaHome = "${cacheDirectory}/lima";
  downloadCache = "${limaHome}/_cache";
  exchange = "${limaHome}/_exchange";
  instance = "linux-gate-v1";
  context = "lima-${instance}";
  socket = "unix://${limaHome}/${instance}/sock/docker.sock";
  settings = (pkgs.formats.yaml { }).generate "${instance}-settings.yaml" {
    vmType = "vz";
    arch = "aarch64";
    cpus = 16;
    memory = "32GiB";
    disk = "160GiB";
    vmOpts.vz.rosetta = {
      enabled = true;
      binfmt = true;
    };
    mountType = "virtiofs";
    mounts = [
      {
        location = exchange;
        mountPoint = "/mnt/exchange";
        writable = true;
      }
    ];
    ssh = {
      loadDotSSHPubKeys = false;
      forwardAgent = false;
      forwardX11 = false;
    };
    propagateProxyEnv = false;
    portForwards = [
      {
        guestSocket = "/var/run/docker.sock";
        hostSocket = "{{.Dir}}/sock/docker.sock";
      }
      {
        guestIP = "0.0.0.0";
        guestIPMustBeZero = false;
        guestPortRange = [
          1
          65535
        ];
        proto = "any";
        ignore = true;
      }
    ];
    message = "Use docker --context ${context}; keep test files on the guest disk, not /mnt/exchange.";
  };
  # Reuse the pinned Docker provisioning rather than maintaining a second copy.
  # Lima 2.1.3 templates/docker-rootful.yaml imports _default/mounts (the host
  # home); pkg/limatmpl/embed.go APPENDS mount lists, so a mounts override alone
  # would retain it. Replace that base with only the package's pinned image base.
  template = pkgs.runCommand "${instance}.yaml" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
    yq '.base = ["${pkgs.lima}/share/lima/templates/_images/ubuntu-lts.yaml"] |
        . * load("${settings}")' \
      ${pkgs.lima}/share/lima/templates/docker-rootful.yaml > "$out"
  '';
in
{
  # Opt-in Linux engine for a project's Linux test gate. Rootful Docker INSIDE
  # the VM preserves CI UID/GID and capability semantics without rootless user
  # namespace remapping; run test containers with their non-root CI UID/GID.
  # The only host mount is a dedicated exchange directory. Import source onto
  # the Linux disk (or a Docker volume), and never mount the engine socket into
  # a test container. Rosetta runs amd64 userspace on an arm64 Linux kernel.
  #
  # Once, after activation:
  #   limactl create --name linux-gate-v1 ~/.config/lima/linux-gate-v1.yaml
  # Then, explicitly (nothing starts at login or activation):
  #   limactl start linux-gate-v1
  #   docker --context lima-linux-gate-v1 run --platform linux/amd64 ...
  #   limactl stop linux-gate-v1
  # Heavy gates must keep the VM host agent under the memory queue for its
  # entire lifetime: membrake exec --label "project: linux gate" -- limactl
  # start --foreground linux-gate-v1 (stop it from the consumer's cleanup).
  # Verify VZ process/group memory accounting before qualifying a gate.
  # No context switch or global DOCKER_HOST: a stopped VM cannot change the
  # default engine. The socket is below the user's 0700 LIMA_HOME, never TCP.
  # Template changes apply to newly created instances; Lima owns existing ones.
  # Keep persistent VM state directly under caches/lima, NEVER caches/tmp or
  # caches/rust: caches.nix's prune-caches only traverses those two trees.
  config = lib.mkIf enabled {
    assertions = [
      {
        assertion = lib.hasPrefix "/Volumes/" cacheDirectory;
        message = "Lima requires cacheDirectory on an external volume under /Volumes/.";
      }
    ];

    home.packages = [ pkgs.lima ];
    home.sessionVariables.LIMA_HOME = limaHome;
    xdg.configFile."lima/${instance}.yaml".source = template;

    # Lima 2.1.3 pkg/downloader/downloader.go WithCache uses os.UserCacheDir,
    # which is ~/Library/Caches on Darwin, regardless of XDG_CACHE_HOME.
    # Keep downloaded guest images external too; refuse an unmanaged collision.
    home.file."Library/Caches/lima".source = config.lib.file.mkOutOfStoreSymlink downloadCache;

    # Docker's context store keys metadata by SHA-256 of the context name
    # (docker/cli cli/context/store). Own only this named context, not config.json
    # or its currentContext. Home Manager refuses an unmanaged-file collision.
    home.file.".docker/contexts/meta/${builtins.hashString "sha256" context}/meta.json".text =
      builtins.toJSON
        {
          Name = context;
          Metadata.Description = "Opt-in Linux test gate VM";
          Endpoints.docker = {
            Host = socket;
            SkipTLSVerify = false;
          };
        };

    home.activation.validateLimaDirectories = lib.hm.dag.entryBefore [ "writeBoundary" ] ''
      for directory in ${
        lib.escapeShellArgs [
          limaHome
          exchange
          downloadCache
        ]
      }; do
        if [[ -L "$directory" || ( -e "$directory" && ( ! -d "$directory" || ! -O "$directory" ) ) ]]; then
          echo "Lima requires an owned directory, not a symlink: $directory" >&2
          exit 1
        fi
        if [[ -d "$directory" && "$(/usr/bin/stat -f '%Lp' "$directory")" != 700 ]]; then
          echo "Lima requires private directory permissions (0700): $directory" >&2
          exit 1
        fi
      done
    '';
    home.activation.ensureLimaDirectories = lib.hm.dag.entryAfter [ "ensureCacheDirectories" ] ''
      run mkdir -p -m 700 ${
        lib.escapeShellArgs [
          limaHome
          exchange
          downloadCache
        ]
      }
    '';
  };
}
