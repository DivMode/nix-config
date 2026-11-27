{
  config,
  lib,
  local,
  pkgs,
  ...
}:
let
  legacy = local.ciRunnerVm or null;
  declared = local.ciRunnerVms or { };
  vms = lib.mapAttrs mkVm (declared // lib.optionalAttrs (legacy != null) { ci-runner-v1 = legacy; });
  vmList = lib.attrValues vms;
  cacheDirectory = local.cacheDirectory or null;
  enabled =
    vmList != [ ]
    && pkgs.stdenv.hostPlatform.isDarwin
    && pkgs.stdenv.hostPlatform.isAarch64
    && cacheDirectory != null;

  limaHome = "${cacheDirectory}/lima";
  mkVm =
    instance: cfg:
    let
      isLegacy = legacy != null && instance == "ci-runner-v1";
      runnerName = cfg.name or (if isLegacy then "mac-vm-1" else instance);
      requestedRunners = if isLegacy then 1 else cfg.runners or 1;
      runnerCount =
        if builtins.isInt requestedRunners && requestedRunners > 0 then
          requestedRunners
        else
          throw "ciRunnerVms.runners must be a positive integer";
      runners = lib.genList (
        index:
        let
          suffix = if index == 0 then "" else "-${toString (index + 1)}";
        in
        {
          name = "${runnerName}${suffix}";
          directory = "/opt/actions-runner${suffix}";
          service = "github-runner${suffix}";
          scriptName = "${registerName}${suffix}";
        }
      ) runnerCount;
      firstRunner = builtins.head runners;
      labels = lib.concatStringsSep "," (cfg.labels or [ "mac-vm" ]);
      agentName = if isLegacy then "ci-runner-vm" else "ci-runner-vm-${instance}";
      startName = "nix-config-${agentName}-start";
      registerName = "nix-config-${agentName}-register";

      # GitHub's Linux arm64 runner. The runner updates itself after it registers,
      # so this pin only decides what a new VM starts from.
      runnerVersion = "2.338.2";
      runnerSha256 = "670adb2f268fe21dcbb58b3db0e0aa9d5b3bddfe2c651481336e561ff86de945";

      # The GitHub CLI that CI steps call. Not the distribution's package: Ubuntu
      # 26.04 ships gh 2.46, which lacks `gh api --slurp` (added in 2.48), and on
      # 2026-11-15 a deploy gate that pages through the API with it failed closed
      # on this runner (`GitHub API failed`, gh printing its usage).
      ghVersion = "2.104.0";
      ghSha256 = "cb34cefc6f4e77b90731374a2b737516bb8f3033c6ca46aa949e5344f68069e3";

      # Runs as root inside the guest on every boot (Lima `provision`, mode
      # system), after the Docker provisioning this template inherits. Idempotent:
      # each step checks for its own result.
      provisionRunner = runner: ''
        #!/bin/bash
        set -eux -o pipefail

        id runner >/dev/null 2>&1 || useradd --create-home --shell /bin/bash runner
        usermod --append --groups docker runner

        # What CI steps expect on a runner host beyond Docker, git and curl.
        packages="jq unzip zip python3-pip python3-venv"
        missing=""
        for package in $packages; do
          dpkg -s "$package" >/dev/null 2>&1 || missing="$missing $package"
        done
        if [ -n "$missing" ]; then
          apt-get update
          # shellcheck disable=SC2086
          DEBIAN_FRONTEND=noninteractive apt-get install -y $missing
        fi

        if [ "$(/usr/local/bin/gh --version 2>/dev/null | awk 'NR==1 {print $3}')" != "${ghVersion}" ]; then
          archive=/tmp/gh.tar.gz
          curl -fsSL -o "$archive" \
            "https://github.com/cli/cli/releases/download/v${ghVersion}/gh_${ghVersion}_linux_arm64.tar.gz"
          echo "${ghSha256}  $archive" | sha256sum -c -
          tar -xzf "$archive" -C /tmp
          install -m 755 "/tmp/gh_${ghVersion}_linux_arm64/bin/gh" /usr/local/bin/gh
          rm -r "$archive" "/tmp/gh_${ghVersion}_linux_arm64"
        fi

        dir=${runner.directory}
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
        cd ${runner.directory}
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

        cat > /etc/systemd/system/${runner.service}.service <<'UNIT'
        [Unit]
        Description=GitHub Actions runner
        After=network-online.target docker.service
        Wants=network-online.target
        ConditionPathExists=${runner.directory}/.runner

        [Service]
        User=runner
        WorkingDirectory=${runner.directory}
        ExecStart=${runner.directory}/run.sh
        Restart=always
        RestartSec=10

        [Install]
        WantedBy=multi-user.target
        UNIT
        systemctl daemon-reload
        systemctl enable ${runner.service}.service
        # A no-op until the runner is registered (ConditionPathExists).
        systemctl start ${runner.service}.service || true
        # On tmpfs: says this boot's provisioning reached its end.
        touch /run/ci-runner-provisioned
      '';

      # Retain runner 1's original script verbatim. Additional installations
      # never copy its registration or work directory.
      provision = pkgs.writeText "${instance}-provision.sh" (provisionRunner firstRunner);

      # Reconcile after the first runner is provisioned. Keeping this out of
      # the Lima template also keeps the start script and launchd plist stable
      # when only the count changes. Activation and registration can both call
      # this, so serialize installations in the same guest.
      reconcileGuestText = ''
        #!/bin/bash
        set -euo pipefail
        exec 9>/run/ci-runner-reconcile.lock
        flock 9
        ${lib.concatMapStrings provisionRunner (builtins.tail runners)}

        # Keep retired credentials intact, but stop surplus processes. Report
        # the actual registered name from .runner, including renamed runners.
        repository=${lib.escapeShellArg cfg.repository}
        for directory in /opt/actions-runner-[0-9]*; do
          [ -d "$directory" ] || continue
          index="''${directory##*/actions-runner-}"
          [[ "$index" =~ ^[1-9][0-9]*$ ]] || continue
          [ "$index" -gt ${toString runnerCount} ] || continue
          if [ -f "$directory/.runner" ]; then
            retired_name=$(jq -er '.agentName | select(type == "string" and length > 0)' "$directory/.runner")
            echo "warning: remove runner $retired_name from $repository; it exceeds the declared runner count" >&2
          fi
          unit="github-runner-$index.service"
          if systemctl cat "$unit" >/dev/null 2>&1; then
            systemctl disable --now "$unit"
          fi
        done
      '';
      reconcileGuest = pkgs.writeText "${instance}-reconcile-runners.sh" reconcileGuestText;
      reconcile = pkgs.writeShellApplication {
        name = "nix-config-${agentName}-reconcile";
        runtimeInputs = [ pkgs.lima ];
        text = ''
          # Home Manager activation runs this with a PATH that has no /usr/bin,
          # and limactl execs macOS's sw_vers to resolve a vz instance; without it
          # every lookup failed with "sw_vers: executable file not found"
          # (rebuild 2026-11-16) and this loop waited 30 minutes for a running VM.
          export PATH="$PATH:/usr/bin:/bin:/usr/sbin:/sbin"
          export LIMA_HOME=${lib.escapeShellArg limaHome}
          for _ in $(seq 180); do
            if limactl shell --workdir / ${instance} test -e /run/ci-runner-provisioned 2>/dev/null; then
              break
            fi
            sleep 10
          done
          limactl shell --workdir / ${instance} test -e /run/ci-runner-provisioned || {
            echo "error: ${instance} did not finish provisioning within 30 minutes" >&2
            exit 1
          }
          limactl shell --workdir / ${instance} sudo bash < ${reconcileGuest}
        '';
      };
      reconcileCommand = "${reconcile}/bin/nix-config-${agentName}-reconcile";

      settings = (pkgs.formats.yaml { }).generate "${instance}-settings.yaml" {
        cpus = cfg.cpus or 16;
        memory = cfg.memory or "24GiB";
        disk = cfg.disk or "120GiB";
        message = "CI runner VM: jobs arrive from GitHub; nothing on the host is mounted.";
        # A NAT interface that macOS itself forwards. Lima's default network is a
        # user-mode stack inside the host agent, and launchd starts that agent in
        # the background: on 2026-11-15 a guest started that way reached the
        # internet but was refused instantly by every address on the owner's LAN
        # (`Failed to connect ... after 0 ms`), while a guest whose host agent was
        # started from a terminal reached the same address. That is the pattern of
        # macOS Local Network privacy applied to a background process (hypothesis:
        # no denial was read from the system log). CI needs one LAN service, so
        # the guest gets a second interface whose traffic does not pass through
        # the host agent.
        networks = [ { vzNAT = true; } ];
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
        name = startName;
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

      registerRunner =
        runner:
        let
          runnerName = runner.name;
        in
        pkgs.writeShellApplication {
          name = runner.scriptName;
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
            in_guest sudo systemctl stop ${runner.service}.service
            registered=0
            gh api --method POST "repos/$repository/actions/runners/registration-token" --jq .token \
              | in_guest sudo -u runner -H \
                  ${runner.directory}/register.sh "https://github.com/$repository" "$name" "$labels" \
              || registered=$?
            in_guest sudo systemctl start ${runner.service}.service
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
            echo "see: limactl shell ${instance} sudo journalctl -u ${runner.service} -n 50" >&2
            exit 1
          '';
        };
      register =
        if runnerCount == 1 then
          registerRunner firstRunner
        else
          pkgs.writeShellApplication {
            name = registerName;
            text = ''
              if ! ${reconcileCommand}; then
                ${lib.concatMapStringsSep "\n" (runner: ''
                  echo ${lib.escapeShellArg "error: could not prepare runner ${runner.name} in VM ${instance}"} >&2
                '') runners}
                exit 1
              fi
              status=0
              ${lib.concatMapStringsSep "\n" (runner: ''
                if ${registerRunner runner}/bin/${runner.scriptName}; then
                  :
                else
                  echo ${lib.escapeShellArg "error: registration failed for runner ${runner.name} in VM ${instance}"} >&2
                  status=1
                fi
              '') runners}
              exit "$status"
            '';
          };
    in
    {
      inherit
        template
        start
        register
        runnerName
        agentName
        reconcileCommand
        ;
      runnerNames = map (runner: runner.name) runners;
      agent = {
        enable = true;
        config = {
          ProgramArguments = [ "${start}/bin/${startName}" ];
          RunAtLoad = true;
          KeepAlive = true;
          ThrottleInterval = 60;
          ProcessType = "Interactive";
          EnvironmentVariables.PATH = "/usr/bin:/bin:/usr/sbin:/sbin";
          StandardOutPath = "${config.home.homeDirectory}/Library/Logs/${agentName}.log";
          StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/${agentName}.log";
        };
      };
      registerCommand = "${register}/bin/${registerName}";
    };

  # Keep the legacy-only command byte-identical. For multiple VMs, run each
  # registration as a separate process so its fail-closed exits and errexit
  # remain local to that VM, while the others are still attempted.
  registerAll =
    if legacy != null && declared == { } then
      vms.ci-runner-v1.register
    else
      pkgs.writeShellApplication {
        name = "nix-config-ci-runner-vm-register";
        text = ''
          status=0
          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (instance: vm: ''
              if ${vm.registerCommand}; then
                :
              else
                echo ${lib.escapeShellArg "error: registration failed for VM ${instance}"} >&2
                status=1
              fi
            '') vms
          )}
          exit "$status"
        '';
      };

in
{
  # Linux CI runners, each for its own repository in a VM on this Mac. The
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
  # VZ. The exposure is the sum of the guest sizes plus VZ overhead: 24 GiB
  # per VM by default, plus 32 GiB if the gate VM runs as well.
  #
  # Budget a warmed-up VM at its whole configured size, not its jobs' peak.
  # Observed on 2026-11-27 with a 40 GiB runner: the guest held 24.5 GB of
  # page cache; dropping it freed 23.7 GB in the guest, and over the next
  # minute its VZ process stayed at 40G MEM and 64-70G CMPRS in
  # `top -o cmprs`. Its virtio balloon had not negotiated free-page reporting
  # (feature bit 5 unset in
  # /sys/bus/virtio/drivers/virtio_balloon/virtio*/features), a possible
  # explanation (untested). Size `memory` to the jobs' measured peak
  # (MemTotal - MemAvailable in the guest over a full run) plus headroom, not
  # to the sum of their container limits.
  #
  # Template changes apply to a newly created instance; Lima owns an existing
  # one. To rebuild it: `limactl stop ci-runner-v1 && limactl delete
  # ci-runner-v1`, then let launchd start it again and re-run the registration.
  config = lib.mkIf enabled {
    assertions = [
      {
        assertion = legacy == null || !(declared ? ci-runner-v1);
        message = "ciRunnerVm and ciRunnerVms cannot both declare ci-runner-v1.";
      }
      {
        assertion = builtins.all (
          instance:
          builtins.match "[a-zA-Z0-9][a-zA-Z0-9_.-]*" instance != null && instance != "linux-gate-v1"
        ) (builtins.attrNames vms);
        message = "ciRunnerVms keys must be Lima instance names (alphanumeric first, then alphanumeric, dot, underscore or hyphen), excluding the reserved linux-gate-v1.";
      }
      {
        assertion =
          let
            names = lib.concatMap (vm: vm.runnerNames) vmList;
          in
          builtins.length (lib.unique names) == builtins.length names;
        message = "CI runner VM names must be distinct; set a unique name for each VM.";
      }
    ];
    # The existing single-runner template and registration stay byte-identical.
    # Reconcile counts separately so lowering back to one also stops and names
    # surplus runners. The legacy form has no reconciliation step.
    home.activation = lib.optionalAttrs (declared != { }) {
      reconcileCiRunnerVms = lib.hm.dag.entryAfter [ "setupLaunchAgents" ] ''
        ci_runner_status=0
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (instance: _: ''
            if ! run ${vms.${instance}.reconcileCommand}; then
              echo ${lib.escapeShellArg "error: could not reconcile runners in VM ${instance}"} >&2
              ci_runner_status=1
            fi
          '') declared
        )}
        if [ "$ci_runner_status" -ne 0 ]; then
          exit "$ci_runner_status"
        fi
      '';
    };
    home.packages = map (vm: vm.start) vmList ++ [ registerAll ];
    xdg.configFile = lib.mapAttrs' (
      instance: vm: lib.nameValuePair "lima/${instance}.yaml" { source = vm.template; }
    ) vms;
    launchd.agents = lib.listToAttrs (map (vm: lib.nameValuePair vm.agentName vm.agent) vmList);
  };
}
