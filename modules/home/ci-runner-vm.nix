{
  config,
  lib,
  local,
  orbstack,
  pkgs,
  ...
}:
let
  vms = lib.mapAttrs mkVm (local.ciRunnerVms or { });
  vmList = lib.attrValues vms;
  enabled = vmList != [ ] && pkgs.stdenv.hostPlatform.isDarwin && pkgs.stdenv.hostPlatform.isAarch64;

  inherit (orbstack) orb;
  requireOrb = ''
    if [ ! -x ${orb} ]; then
      echo "error: OrbStack is required at ${orb} (install the orbstack cask)" >&2
      exit 1
    fi
  '';
  mkVm =
    instance: cfg:
    let
      guest = "${orb} -m ${instance} -u root -w /";
      orbRunning = ''
        orb_running() {
          local machines
          machines=$(${orb} list --running --quiet) || return 1
          grep -qxF -- ${instance} <<< "$machines"
        }
      '';
      guestSetup = ''
        ${requireOrb}
        ${orbRunning}
        in_running_guest() {
          # "orb -m ... test -e /run/ci-runner-provisioned" moved a
          # stopped probe to Running. Let launchd start and provision it.
          orb_running || return 1
          ${guest} "$@"
        }
      '';
      runnerName = cfg.name or instance;
      requestedRunners = cfg.runners or 1;
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
      agentName = "ci-runner-vm-${instance}";
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

      # Optional `nix = true`: multi-user Nix with flakes, for job steps that
      # call `nix shell` or `nix develop`. It comes from Ubuntu's own packages
      # (nix-setup-systemd, which pulls nix-bin: Nix 2.34.3 in 26.04), so dpkg
      # makes the install idempotent and resumable; the release tarball's
      # installer refused to rerun after an interruption. `nix` lands in
      # /usr/bin, already on the runner's PATH. Flakes are enabled for the
      # runner through NIX_CONFIG rather than in /etc/nix/nix.conf, which is a
      # dpkg conffile. A running runner picks up a unit change at its next
      # start: provisioning never restarts a runner that may be running a job,
      # so switching `nix` on for online runners takes an idle restart of each.
      nixEnabled = cfg.nix or false;
      nixUnitEnvironment = lib.optionalString nixEnabled ''
        Environment="NIX_CONFIG=experimental-features = nix-command flakes"
      '';

      # Runs as root inside the guest after Docker provisioning. Idempotent:
      # each step checks for its own result.
      provisionRunner = runner: ''
        #!/bin/bash
        set -eux -o pipefail

        id runner >/dev/null 2>&1 || useradd --create-home --shell /bin/bash runner
        usermod --append --groups docker runner
        ${lib.optionalString nixEnabled ''
          # The Nix daemon's socket directory is 770 root:nix-users
          # (/usr/lib/tmpfiles.d/nix-daemon.conf in nix-setup-systemd).
          usermod --append --groups nix-users runner
        ''}

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

        # Each runner's work directory is its own btrfs subvolume, so it has its
        # own tree root lock and its own fsync log. With 20 runners in one
        # subvolume, about 37 of 60 sampled D-state processes waited in
        # btrfs_read_lock_root_node and 8 in wait_log_commit (/proc/<pid>/wchan,
        # 2026-11-28), while the VM's CPU stayed 72-79% idle. The unit runs this
        # before each start, when no job can be using the directory. A directory
        # from before is reflink-copied in, so its checkout and tools stay warm.
        # Every runner unit runs the helper, so replace it whole, never in place.
        helper=$(mktemp /usr/local/sbin/.ci-runner-work-subvolume.XXXXXX)
        cat > "$helper" <<'SUBVOLUME'
        #!/bin/bash
        # Converting is only an optimisation: whenever it cannot be done safely
        # now, start the runner on the directory as it is and try next start.
        set -euo pipefail
        work="$1" new="$1.new" old="$1.old"
        # A btrfs subvolume's top directory is always inode 256. Checking the
        # path itself avoids "subvolume show", which lists every subvolume and
        # fails when another runner deletes one at the same time.
        is_subvolume() {
          [ "$(stat -c %i "$1" 2>/dev/null)" = 256 ]
        }
        if is_subvolume "$work" && [ ! -e "$old" ]; then
          exit 0
        fi
        skip() {
          echo "not converting $work now: $1" >&2
          exit 0
        }
        command -v btrfs >/dev/null || skip "btrfs-progs is not installed yet"
        # A job container that outlived a crashed runner, in any state but
        # exited, keeps the old directory mounted.
        containers=$(docker ps -q --filter status=created --filter status=running \
          --filter status=restarting --filter status=paused --filter status=removing) ||
          skip "docker ps failed"
        # Inspected one by one: on a busy machine other runners' containers
        # exit between "docker ps" and "docker inspect", which then says
        # exactly "error: no such object: <id>" (runner 5, 2026-11-28). Only that
        # whole answer means the container is gone and holds no mount; any other
        # output, such as an unreachable daemon, leaves it unknown.
        mounts=""
        for container in $containers; do
          if inspected=$(docker inspect --format '{{range .Mounts}}{{println .Source}}{{end}}' "$container" 2>&1); then
            mounts+="$inspected"$'\n'
          elif [ "$inspected" != "error: no such object: $container" ]; then
            skip "the mounts of container $container could not be read"
          fi
        done
        if grep -qF -- "$work" <<< "$mounts"; then
          skip "it is mounted in a container"
        fi
        # A conversion stopped between its two renames: put the original back,
        # over the empty work directory the runner may have made since.
        if [ -d "$old" ] && ! is_subvolume "$work"; then
          if [ -e "$work" ]; then
            rm -r "$work"
          fi
          mv -T "$old" "$work"
        fi
        if ! is_subvolume "$work"; then
          if is_subvolume "$new"; then
            btrfs subvolume delete "$new"
          fi
          btrfs subvolume create "$new"
          if [ -d "$work" ]; then
            cp -a --reflink=auto "$work/." "$new/"
          fi
          chown runner:runner "$new"
          if [ -d "$work" ]; then
            mv -T "$work" "$old"
          fi
          mv -T "$new" "$work"
        fi
        # Also finishes a removal a previous start did not complete.
        if [ -e "$old" ]; then
          rm -r "$old"
        fi
        SUBVOLUME
        chmod 755 "$helper"
        mv -f "$helper" /usr/local/sbin/ci-runner-work-subvolume

        cat > /etc/systemd/system/${runner.service}.service <<'UNIT'
        [Unit]
        Description=GitHub Actions runner
        After=network-online.target docker.service
        Wants=network-online.target
        ConditionPathExists=${runner.directory}/.runner

        [Service]
        ${nixUnitEnvironment}User=runner
        # Every runner on a machine shares the runner user's HOME, and rustup
        # is not safe for concurrent use (rust-lang/rustup#988, open): two jobs
        # installing one toolchain into /home/runner/.rustup at once failed with
        # "could not rename 'downloaded' file" (2026-11-28). So each runner keeps
        # its toolchains in its own work subvolume, about 1.3 GB per runner that
        # uses Rust. Cargo locks its own package cache, so CARGO_HOME stays shared.
        Environment=RUSTUP_HOME=${runner.directory}/_work/_rustup
        WorkingDirectory=${runner.directory}
        # "-" and the 5-minute limit: a failed or stalled conversion never keeps
        # the runner from starting. A 2.4 GB, 39k-file work directory copies in
        # well under that; the start limit stays above it.
        ExecStartPre=-+/usr/bin/timeout 5m /usr/local/sbin/ci-runner-work-subvolume ${runner.directory}/_work
        TimeoutStartSec=10min
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
      '';

      # Reconcile after the first runner is provisioned, independently of the
      # launchd agent. Activation and registration can both call this, so
      # serialize installations in the same guest.
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
        text = ''
          # Home Manager's activation PATH omits the system tools used below.
          export PATH="$PATH:/usr/bin:/bin:/usr/sbin:/sbin"
          ${guestSetup}
          for _ in $(seq 180); do
            if in_running_guest grep -qx ${provisionStamp} /run/ci-runner-provisioned 2>/dev/null; then
              break
            fi
            sleep 10
          done
          in_running_guest grep -qx ${provisionStamp} /run/ci-runner-provisioned || {
            echo "error: ${instance} did not finish provisioning within 30 minutes" >&2
            exit 1
          }
          in_running_guest sudo bash < ${reconcileGuest}
        '';
      };
      reconcileCommand = "${reconcile}/bin/nix-config-${agentName}-reconcile";

      cpus = toString (lib.toIntBase10 (toString (cfg.cpus or 0)));
      memoryMiB =
        if !(cfg ? memory) then
          "0"
        else
          let
            parts =
              if builtins.isString cfg.memory then builtins.match "([1-9][0-9]*)(GiB|MiB)" cfg.memory else null;
            size = lib.toInt (builtins.elemAt parts 0) * (if builtins.elemAt parts 1 == "GiB" then 1024 else 1);
          in
          # OrbStack 2.2.5 `create --memory 768`: "memory limit must be at least 1 GiB".
          if parts == null || size < 1024 then
            throw "ciRunnerVms.${instance}.memory must be at least 1 GiB, specified in whole GiB or MiB"
          else
            toString size;
      createArgs = lib.escapeShellArgs (
        [ "--isolated" ]
        ++ lib.optionals (cfg ? cpus) [
          "--cpus"
          cpus
        ]
        ++ lib.optionals (cfg ? memory) [
          "--memory"
          memoryMiB
        ]
        ++ [
          "ubuntu"
          instance
        ]
      );

      # `orb config show` prints dotted names as machine."example.ci".cpu.
      machineConfig =
        if lib.hasInfix "." instance then ''machine."${instance}"'' else "machine.${instance}";

      # The marker on tmpfs says this boot's provisioning reached its end, and
      # holds a stamp of the script that wrote it. Reconcile and registration
      # wait for this script's stamp, not merely for the file: right after an
      # activation the previous script's marker can still be there, before the
      # relaunched agent has removed it.
      provisionStamp = builtins.substring 0 16 (builtins.hashString "sha256" orbProvisionBody);
      orbProvision = pkgs.writeText "${instance}-orbstack-provision.sh" (
        orbProvisionBody
        + ''
          echo ${provisionStamp} > /run/ci-runner-provisioned
        ''
      );
      orbProvisionBody = ''
        #!/bin/bash
        set -euo pipefail
        if [ -e /run/ci-runner-provisioned ]; then
          unlink /run/ci-runner-provisioned
        fi
        # A dpkg run cut off by a reboot leaves its journal dirty, and APT then
        # refuses every install below; this finishes it, and does nothing on a
        # clean system.
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a

        # OrbStack 2.2.5 adds Mac tool links and a login PATH hook even in an
        # isolated machine. Leave them out of runner shells. Running
        # mac /usr/bin/true returned "dial: no such file or directory".
        for tool in mac macctl; do
          if [ "$(readlink "/usr/local/bin/$tool")" = "/opt/orbstack-guest/bin/$tool" ]; then
            unlink "/usr/local/bin/$tool"
          fi
        done
        profile=/etc/profile.d/999-orbstack.sh
        if [ "$(readlink "$profile")" = /opt/orbstack-guest/etc/profile-late ]; then
          unlink "$profile"
        fi

        # The OrbStack Ubuntu image lacks the Git and jq packages.
        if ! command -v git >/dev/null || ! command -v jq >/dev/null; then
          apt-get update
          DEBIAN_FRONTEND=noninteractive apt-get install -y git jq
        fi
        # The runner units' work-subvolume helper needs btrfs-progs, but runs
        # without it (it skips converting), so a failed download must not stop
        # provisioning. Installed here only: this runs once per boot, outside
        # reconcile's lock, so a second apt-get in provisionRunner could race
        # it for the APT lock.
        if ! command -v btrfs >/dev/null; then
          if ! { apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y btrfs-progs; }; then
            echo "warning: btrfs-progs not installed; runner work directories stay unconverted" >&2
          fi
        fi
        # Install rootful Docker with CDI and the containerd image store.
        if ! command -v docker >/dev/null; then
          export DEBIAN_FRONTEND=noninteractive
          curl -fsSL https://get.docker.com | sh
        fi
        daemon_config=/etc/docker/daemon.json
        desired_config=$(mktemp)
        trap 'unlink "$desired_config"' EXIT
        if [ -f "$daemon_config" ]; then
          cat "$daemon_config"
        else
          echo '{}'
        fi | jq -S '.features.cdi = true | .features["containerd-snapshotter"] = true' > "$desired_config"
        if ! cmp -s "$desired_config" "$daemon_config"; then
          install -D -m 644 "$desired_config" "$daemon_config"
          systemctl restart docker.service
        fi
        systemctl enable --now docker.service

        # A gate sets LANG=en_US.UTF-8 and runs initdb, whose collation depends
        # on the locale existing. `locale -a` lists a generated one as en_US.utf8.
        generated_locales=$(locale -a)
        if ! grep -qiE '^en_US\.utf-?8$' <<< "$generated_locales"; then
          if ! dpkg -s locales >/dev/null 2>&1; then
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y locales
          fi
          locale-gen en_US.UTF-8
        fi
        ${lib.optionalString nixEnabled ''
          # Here, once per boot, for the same APT lock reason as btrfs-progs
          # above.
          nix_package=$(dpkg -s nix-setup-systemd 2>/dev/null || true)
          if ! grep -qx 'Status: install ok installed' <<< "$nix_package"; then
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y nix-setup-systemd
          fi
          # The package enables and starts nix-daemon.service itself; its socket
          # unit then refuses to listen ("Socket service nix-daemon.service
          # already active"), so this ensures the service, not the socket.
          systemctl enable --now nix-daemon.service
        ''}
        ${provisionRunner firstRunner}
      '';
      start = pkgs.writeShellApplication {
        name = startName;
        runtimeInputs = [ pkgs.jq ];
        text = ''
          ${requireOrb}
          ${orb} start
          machine_info() {
            ${orb} list --format json | jq -c --arg name ${instance} '.[] | select(.name == $name)'
          }
          machine=$(machine_info)
          if [ -z "$machine" ]; then
            ${orb} create ${createArgs}
            machine=$(machine_info)
          fi
          if [ -z "$machine" ] || ! jq -e '.config.isolated and (.config.forward_ssh_agent == false)
                                  and ((.config.mounts // []) | length == 0)' <<< "$machine" >/dev/null; then
            echo "error: OrbStack machine ${instance} must be isolated with no host mounts or SSH agent forwarding" >&2
            exit 1
          fi

          # OrbStack 2.2.5 applied config set live: the probe's cpu.max and
          # memory.max changed to 200000 100000 and 4294967296 with the same PID 1.
          # Zero shares the global limit (docs.orbstack.dev/machines#resource-limits).
          current=$(${orb} config show)
          for setting in cpu=${cpus} memory_mib=${memoryMiB}; do
            key=${lib.escapeShellArg machineConfig}."''${setting%%=*}"
            value="''${setting#*=}"
            if ! grep -Fxq -- "$key: $value" <<< "$current"; then
              ${orb} config set "$key" "$value"
            fi
          done

          ${orbRunning}
          if ! orb_running; then
            ${orb} start ${instance}
          fi
          ${guest} bash < ${orbProvision}
          # A reboot can finish between polls. Its tmpfs marker is gone.
          while orb_running && ${guest} test -e /run/ci-runner-provisioned; do sleep 60; done
        '';
      };

      registerRunner =
        runner:
        let
          runnerName = runner.name;
        in
        pkgs.writeShellApplication {
          name = runner.scriptName;
          runtimeInputs = [ pkgs.jq ];
          text = ''
            # Registers the VM's runner when GitHub does not list it as online, then
            # waits until it is. Runs as the owner: only the owner's `gh` login may
            # issue a registration token. The token goes to the guest on stdin, lives
            # an hour, and only registers runners; the runner's lasting credential
            # stays on the VM's own disk.
            ${guestSetup}
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
              in_running_guest "$@"
            }
            if online_or_stop; then
              echo "runner $name is online"
              exit 0
            fi

            # First boot downloads the guest image, installs Docker and the runner.
            echo "waiting for the VM to finish provisioning"
            for _ in $(seq 180); do
              if in_guest grep -qx ${provisionStamp} /run/ci-runner-provisioned 2>/dev/null; then
                break
              fi
              sleep 10
            done
            in_guest grep -qx ${provisionStamp} /run/ci-runner-provisioned || {
              echo "error: ${instance} did not finish provisioning within 30 minutes" >&2
              echo "see ${orb} logs ${instance} and ~/Library/Logs/${agentName}.log" >&2
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
            echo "see: ${guest} sudo journalctl -u ${runner.service} -n 50" >&2
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
        start
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

  # Run each registration as a separate process so an error stays local to
  # that machine while the others are still attempted.
  registerAll = pkgs.writeShellApplication {
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
  # OrbStack uses isolated machines without Mac integration, SSH agent
  # forwarding or automatic port forwards (./orbstack.nix).
  # OrbStack machines share its Linux kernel rather than booting their own.
  #
  # It starts at login and stays up (launchd KeepAlive). This Mac has no
  # automatic login, so after a restart the runner is offline until the owner
  # logs in.
  #
  # OrbStack returns unused memory to macOS. In the 2026-11-27 Lima VZ
  # measurement, the guest freed 23.7 GB of page cache while `top -o cmprs`
  # showed its host process staying at 40G MEM and 64-70G CMPRS for a minute.
  config = lib.mkIf enabled {
    assertions = [
      {
        assertion = builtins.all (instance: builtins.match "[a-zA-Z0-9][a-zA-Z0-9_.-]*" instance != null) (
          builtins.attrNames vms
        );
        message = "ciRunnerVms keys must be instance names (alphanumeric first, then alphanumeric, dot, underscore or hyphen).";
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
    # Reconcile counts separately so lowering back to one also stops and names
    # surplus runners.
    home.activation.reconcileCiRunnerVms = lib.hm.dag.entryAfter [ "setupLaunchAgents" ] ''
      ci_runner_status=0
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (instance: vm: ''
          if ! run ${vm.reconcileCommand}; then
            echo ${lib.escapeShellArg "error: could not reconcile runners in VM ${instance}"} >&2
            ci_runner_status=1
          fi
        '') vms
      )}
      if [ "$ci_runner_status" -ne 0 ]; then
        exit "$ci_runner_status"
      fi
    '';
    home.packages = map (vm: vm.start) vmList ++ [ registerAll ];
    launchd.agents = lib.listToAttrs (map (vm: lib.nameValuePair vm.agentName vm.agent) vmList);
  };
}
