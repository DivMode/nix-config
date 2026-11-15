{
  config,
  lib,
  local,
  pkgs,
  ...
}:
let
  cfg = local.ciRunnerVm or null;
  cacheDirectory = local.cacheDirectory or null;
  enabled =
    cfg != null
    && pkgs.stdenv.hostPlatform.isDarwin
    && pkgs.stdenv.hostPlatform.isAarch64
    && cacheDirectory != null;

  limaHome = "${cacheDirectory}/lima";
  instance = "ci-runner-v1";
  runnerName = cfg.name or "mac-vm-1";
  labels = lib.concatStringsSep "," (cfg.labels or [ "mac-vm" ]);

  # GitHub's Linux arm64 runner. The runner updates itself after it registers,
  # so this pin only decides what a new VM starts from.
  runnerVersion = "2.338.2";
  runnerSha256 = "670adb2f268fe21dcbb58b3db0e0aa9d5b3bddfe2c651481336e561ff86de945";

  # Runs as root inside the guest on every boot (Lima `provision`, mode
  # system), after the Docker provisioning this template inherits. Idempotent:
  # each step checks for its own result.
  provision = pkgs.writeText "${instance}-provision.sh" ''
    #!/bin/bash
    set -eux -o pipefail

    id runner >/dev/null 2>&1 || useradd --create-home --shell /bin/bash runner
    usermod --append --groups docker runner

    # What CI steps expect on a runner host beyond Docker, git and curl.
    packages="jq unzip zip gh python3-pip python3-venv"
    missing=""
    for package in $packages; do
      dpkg -s "$package" >/dev/null 2>&1 || missing="$missing $package"
    done
    if [ -n "$missing" ]; then
      apt-get update
      # shellcheck disable=SC2086
      DEBIAN_FRONTEND=noninteractive apt-get install -y $missing
    fi

    dir=/opt/actions-runner
    # The marker is written last, so an install interrupted anywhere (download,
    # dependencies, ownership) is redone on the next boot instead of skipped.
    if [ ! -f "$dir/.installed" ]; then
      mkdir -p "$dir"
      archive=/tmp/actions-runner.tar.gz
      curl -fsSL -o "$archive" \
        "https://github.com/actions/runner/releases/download/v${runnerVersion}/actions-runner-linux-arm64-${runnerVersion}.tar.gz"
      echo "${runnerSha256}  $archive" | sha256sum -c -
      tar -xzf "$archive" -C "$dir"
      rm "$archive"
      "$dir/bin/installdependencies.sh"
      chown -R runner:runner "$dir"
      touch "$dir/.installed"
    fi

    # Registration reads the token from stdin so it never appears in the
    # host's process arguments; nix-config-ci-runner-vm-register drives it.
    cat > "$dir/register.sh" <<'REGISTER'
    #!/bin/bash
    set -euo pipefail
    url="$1" name="$2" labels="$3"
    IFS= read -r token
    cd /opt/actions-runner
    # config.sh refuses to run over an existing registration. Set the old one
    # aside and put it back if the new one fails, so a failed attempt (no
    # network in the guest, an expired token) leaves the runner able to start
    # with the credentials it had.
    state=".runner .credentials .credentials_rsaparams"
    backup=$(mktemp -d)
    for file in $state; do
      [ ! -e "$file" ] || mv "$file" "$backup/"
    done
    if ./config.sh --unattended --replace --url "$url" --name "$name" \
      --labels "$labels" --work _work --token "$token"; then
      rm -r "$backup"
    else
      status=$?
      for file in $state; do
        [ ! -e "$backup/$file" ] || mv -f "$backup/$file" .
      done
      exit "$status"
    fi
    REGISTER
    chmod 755 "$dir/register.sh"
    chown runner:runner "$dir/register.sh"

    cat > /etc/systemd/system/github-runner.service <<'UNIT'
    [Unit]
    Description=GitHub Actions runner
    After=network-online.target docker.service
    Wants=network-online.target
    ConditionPathExists=/opt/actions-runner/.runner

    [Service]
    User=runner
    WorkingDirectory=/opt/actions-runner
    ExecStart=/opt/actions-runner/run.sh
    Restart=always
    RestartSec=10

    [Install]
    WantedBy=multi-user.target
    UNIT
    systemctl daemon-reload
    systemctl enable github-runner.service
    # A no-op until the runner is registered (ConditionPathExists).
    systemctl start github-runner.service || true
    # On tmpfs: says this boot's provisioning reached its end.
    touch /run/ci-runner-provisioned
  '';

  settings = (pkgs.formats.yaml { }).generate "${instance}-settings.yaml" {
    cpus = cfg.cpus or 16;
    memory = cfg.memory or "24GiB";
    disk = cfg.disk or "120GiB";
    message = "CI runner VM: jobs arrive from GitHub; nothing on the host is mounted.";
  };

  # One source for the VM's shape: the Linux gate template (./lima.nix: vz,
  # arm64, Rosetta through binfmt, rootful Docker, no guest ports forwarded),
  # resized, with no host mount at all, without the gate's forward of the
  # guest's Docker socket to the host, and with the runner provisioning
  # appended.
  template =
    pkgs.runCommand "${instance}.yaml"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
        base = config.xdg.configFile."lima/linux-gate-v1.yaml".source;
      }
      ''
        yq '. * load("${settings}") | .mounts = [] |
            .portForwards |= map(select(has("guestSocket") | not)) |
            .provision += [{"mode": "system", "script": load_str("${provision}")}]' \
          "$base" > "$out"
      '';

  # launchd keeps this running. The VM is created on first start; a start that
  # finds it already running (started by hand) just waits for it to stop.
  start = pkgs.writeShellApplication {
    name = "nix-config-ci-runner-vm-start";
    runtimeInputs = [ pkgs.lima ];
    text = ''
      export LIMA_HOME=${lib.escapeShellArg limaHome}
      # The external volume can mount after login.
      until [ -d "$LIMA_HOME" ]; do sleep 5; done
      if ! limactl list --quiet | grep -qxF ${instance}; then
        limactl create --name ${instance} --tty=false ${template}
      fi
      if [ "$(limactl list --format '{{.Status}}' ${instance})" = Running ]; then
        while [ "$(limactl list --format '{{.Status}}' ${instance})" = Running ]; do sleep 60; done
        exit 0
      fi
      exec limactl start --foreground --tty=false ${instance}
    '';
  };

  register = pkgs.writeShellApplication {
    name = "nix-config-ci-runner-vm-register";
    runtimeInputs = [
      pkgs.lima
      pkgs.jq
    ];
    text = ''
      # Registers the VM's runner when GitHub does not list it as online, then
      # waits until it is. Runs as the owner: only the owner's `gh` login may
      # issue a registration token. The token goes to the guest on stdin, lives
      # an hour, and only registers runners; the runner's lasting credential
      # stays on the VM's own disk.
      export LIMA_HOME=${lib.escapeShellArg limaHome}
      repository=${lib.escapeShellArg cfg.repository}
      name=${lib.escapeShellArg runnerName}
      labels=${lib.escapeShellArg labels}

      # 0 online, 1 not listed as online, 2 GitHub could not be asked.
      online() {
        local listed
        listed=$(gh api --paginate "repos/$repository/actions/runners" \
          --jq '.runners[] | select(.status == "online") | .name') || return 2
        grep -qxF -- "$name" <<<"$listed"
      }
      # Exits 0 when online; stops the whole command when GitHub cannot be
      # asked, because "unknown" must never lead to replacing a healthy runner.
      online_or_stop() {
        local status=0
        online || status=$?
        if [ "$status" -eq 2 ]; then
          echo "error: could not list the repository's runners (is gh logged in?)" >&2
          exit 1
        fi
        return "$status"
      }
      in_guest() {
        limactl shell --workdir / ${instance} "$@"
      }
      if online_or_stop; then
        echo "runner $name is online"
        exit 0
      fi

      # First boot downloads the guest image, installs Docker and the runner.
      echo "waiting for the VM to finish provisioning"
      for _ in $(seq 180); do
        if in_guest test -e /run/ci-runner-provisioned 2>/dev/null; then
          break
        fi
        sleep 10
      done
      in_guest test -e /run/ci-runner-provisioned || {
        echo "error: ${instance} did not finish provisioning within 30 minutes" >&2
        echo "see $LIMA_HOME/${instance}/ha.stderr.log and serial*.log" >&2
        exit 1
      }

      # A registered runner that is only booting comes online by itself.
      for _ in $(seq 24); do
        if online_or_stop; then
          echo "runner $name is online"
          exit 0
        fi
        sleep 5
      done

      echo "registering $name"
      # Stopped for the change so the listener cannot pick up a job on
      # credentials that are about to be replaced; started again whether or not
      # the registration worked (a failure restores the previous credentials).
      in_guest sudo systemctl stop github-runner.service
      registered=0
      gh api --method POST "repos/$repository/actions/runners/registration-token" --jq .token \
        | in_guest sudo -u runner -H \
            /opt/actions-runner/register.sh "https://github.com/$repository" "$name" "$labels" \
        || registered=$?
      in_guest sudo systemctl start github-runner.service
      if [ "$registered" -ne 0 ]; then
        echo "error: registration failed; the runner keeps its previous credentials" >&2
        exit 1
      fi

      for _ in $(seq 60); do
        if online_or_stop; then
          echo "runner $name is online"
          exit 0
        fi
        sleep 5
      done
      echo "error: $name is not online after 5 minutes" >&2
      echo "see: limactl shell ${instance} sudo journalctl -u github-runner -n 50" >&2
      exit 1
    '';
  };
in
{
  # A Linux CI runner for one private repository, as a VM on this Mac. The
  # repository's jobs are Linux containers, several of them amd64-only, so they
  # cannot run on the macOS runners (../darwin/github-runners.nix). The guest
  # is arm64 with Rosetta registered through binfmt: arm64 binaries run
  # natively, amd64 containers under Rosetta.
  #
  # Isolation is the VM itself: no host directory is mounted, no guest port or
  # socket is forwarded, and the only way in from the host is Lima's own SSH
  # forward (`limactl shell`, as the owner). A job sees the guest disk, the
  # guest's Docker and the network.
  #
  # It starts at login and stays up (launchd KeepAlive). This Mac has no
  # automatic login, so after a restart the runner is offline until the owner
  # logs in.
  #
  # Unlike the opt-in gate VM (./lima.nix) it does not run under `membrake
  # exec`. That queue admits a job when memory allows and may freeze it later;
  # this VM has to stay reachable for CI at all times. It is NOT protected the
  # way the macOS runners are (../darwin/membrake.nix protects the runner
  # account; this VM runs as the owner), so membrake still sees its host agent
  # as an ordinary process group. Whether membrake can account for or freeze
  # the guest's memory is unverified, the same caveat ./lima.nix records for
  # VZ. The exposure is the guest size plus VZ overhead: 24 GiB by default,
  # 56 GiB of guest memory on this 96 GB Mac if the gate VM runs as well.
  #
  # Template changes apply to a newly created instance; Lima owns an existing
  # one. To rebuild it: `limactl stop ci-runner-v1 && limactl delete
  # ci-runner-v1`, then let launchd start it again and re-run the registration.
  config = lib.mkIf enabled {
    home.packages = [
      start
      register
    ];
    xdg.configFile."lima/${instance}.yaml".source = template;
    launchd.agents.ci-runner-vm = {
      enable = true;
      config = {
        ProgramArguments = [ "${start}/bin/nix-config-ci-runner-vm-start" ];
        RunAtLoad = true;
        KeepAlive = true;
        ThrottleInterval = 60;
        ProcessType = "Interactive";
        EnvironmentVariables.PATH = "/usr/bin:/bin:/usr/sbin:/sbin";
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/ci-runner-vm.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/ci-runner-vm.log";
      };
    };
  };
}
