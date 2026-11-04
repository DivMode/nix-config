{ pkgs, ... }:
let
  # macOS 27.0 and 27.0.1 fseventsd runs away on agent-heavy Macs: after heavy
  # file churn it pins one core for days and its heap ("Malloc Small") grows
  # without bound. On this Mac (macOS 27.0.1, 26A434) it went from 18 MB on
  # 2026-10-29 to 70 GB on 2026-11-02, at about one GB per CPU-hour, until swap
  # ran out and jetsam killed work (/Library/Logs/DiagnosticReports/
  # JetsamEvent-2026-1*.ips). Apple tracks it as FB25046068; no macOS update is
  # known to fix it, and a restart of the daemon frees all of it.
  #
  # Every minute this records fseventsd's footprint and CPU share. Past
  # warnMB, or after cpuMinutes consecutive minutes above cpuPercent, it saves
  # evidence (at most once an hour) so the next runaway names its own trigger.
  # Past restartMB it saves evidence and restarts the daemon (launchd respawns
  # it). `launchctl kickstart -k` is refused under SIP, so it sends TERM, then
  # KILL. Long-running FSEvents clients do not re-register after a restart;
  # Claude Code falls back to polling its settings, other watchers need their
  # process restarted.
  stateDir = "/var/db/fseventsd-guard";
  evidenceDir = "/var/log/fseventsd-guard";

  guard = pkgs.writeShellScript "fseventsd-guard" ''
    set -uo pipefail
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    timeout=${pkgs.coreutils}/bin/timeout

    warn_mb=''${FSEVENTSD_GUARD_WARN_MB:-512}
    restart_mb=''${FSEVENTSD_GUARD_RESTART_MB:-2048}
    cpu_percent=''${FSEVENTSD_GUARD_CPU_PERCENT:-80}
    cpu_minutes=''${FSEVENTSD_GUARD_CPU_MINUTES:-10}
    max_restarts_per_day=12
    keep_evidence=30
    state=${stateDir}
    evidence=${evidenceDir}

    mkdir -p "$state" "$evidence"
    say() { logger -t fseventsd-guard "$*"; }

    pid=$(pgrep -x fseventsd) || exit 0

    # "fseventsd [377]: 64-bit    Footprint: 137 MB (16384 bytes per page)"
    footprint_mb=$(footprint -p "$pid" 2>/dev/null | awk '
      match($0, /Footprint: [0-9.]+ [KMGT]?B/) {
        split(substr($0, RSTART + 11, RLENGTH - 11), f, " ")
        m = (f[2] == "KB") ? 1 / 1024 : (f[2] == "MB") ? 1 : (f[2] == "GB") ? 1024 : (f[2] == "TB") ? 1048576 : 1 / 1048576
        printf "%d\n", f[1] * m
        exit
      }')
    if [[ -z "$footprint_mb" ]]; then
      say "could not read the footprint of fseventsd pid $pid"
      exit 1
    fi

    # ps prints cumulative CPU as [[H:]M]M:SS.ss.
    cpu_seconds=$(ps -o time= -p "$pid" | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; printf "%d\n", s }')
    now=$(date +%s)

    cpu_share=0
    hot=0
    if [[ -f "$state/last" ]] && read -r last_pid last_now last_cpu last_hot < "$state/last" \
      && [[ "$last_pid" == "$pid" ]] && (( now > last_now )); then
      cpu_share=$(( (cpu_seconds - last_cpu) * 100 / (now - last_now) ))
      if (( cpu_share >= cpu_percent )); then hot=$(( last_hot + 1 )); fi
    fi
    echo "$pid $now $cpu_seconds $hot" > "$state/last"
    echo "$(date '+%F %T') pid=$pid footprint_mb=$footprint_mb cpu_percent=$cpu_share hot_minutes=$hot" >> "$state/samples.log"

    capture() {
      local dir="$evidence/$(date +%Y%m%d-%H%M%S)-$1"
      mkdir -p "$dir"
      footprint -p "$pid" > "$dir/footprint.txt" 2>&1
      $timeout 60 vmmap --summary "$pid" > "$dir/vmmap-summary.txt" 2>&1
      $timeout 120 heap -s "$pid" > "$dir/heap.txt" 2>&1
      $timeout 60 sample "$pid" 5 -mayDie -file "$dir/sample.txt" > /dev/null 2>&1
      $timeout 30 lsmp -p "$pid" > "$dir/lsmp.txt" 2>&1
      ps -axo pid,ppid,etime,time,rss,comm > "$dir/processes.txt" 2>&1
      $timeout 120 log show --last 2h --style compact \
        --predicate 'process == "fseventsd"' 2>/dev/null | gzip > "$dir/fseventsd-log.txt.gz"
      ls -laT /System/Volumes/Data/.fseventsd > "$dir/disklog-data.txt" 2>&1
      tail -n 180 "$state/samples.log" > "$dir/samples.txt"
      say "saved evidence in $dir (footprint $footprint_mb MB, cpu $cpu_share%, $1)"
      touch "$state/last-capture"
      ls -1d "$evidence"/*/ 2>/dev/null | sort -r | tail -n +$(( keep_evidence + 1 )) | while read -r old; do
        rm -r "$old"
      done
    }

    if (( footprint_mb >= restart_mb )); then
      recent=0
      if [[ -f "$state/restarts" ]]; then
        recent=$(awk -v since=$(( now - 86400 )) '$1 >= since' "$state/restarts" | wc -l | tr -d ' ')
      fi
      capture "restart"
      if (( recent >= max_restarts_per_day )); then
        say "fseventsd at $footprint_mb MB, but $recent restarts in 24 h already; not restarting"
        exit 1
      fi
      echo "$now" >> "$state/restarts"
      kill -TERM "$pid"
      for _ in $(seq 1 15); do
        sleep 1
        kill -0 "$pid" 2>/dev/null || break
      done
      if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid"; fi
      for _ in $(seq 1 15); do
        sleep 1
        new=$(pgrep -x fseventsd) && break
      done
      say "restarted fseventsd at $footprint_mb MB: pid $pid -> ''${new:-none yet}"
      rm -f "$state/last"
      exit 0
    fi

    if (( footprint_mb >= warn_mb || hot >= cpu_minutes )); then
      if [[ ! -f "$state/last-capture" ]] || (( now - $(stat -f %m "$state/last-capture") >= 3600 )); then
        capture "warn"
      fi
    fi
  '';
in
{
  launchd.daemons.fseventsd-guard = {
    command = "${guard}";
    serviceConfig = {
      StartInterval = 60;
      RunAtLoad = true;
      ProcessType = "Background";
    };
  };

  # samples.log grows by one line a minute (about 4 MB a month); rotate it
  # past 1 MB and keep 3.
  environment.etc."newsyslog.d/fseventsd-guard.conf".text = ''
    ${stateDir}/samples.log  root:wheel  644  3  1024  *  N
  '';
}
