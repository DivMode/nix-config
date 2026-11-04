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

    warn_mb=''${FSEVENTSD_GUARD_WARN_MB:-512}
    restart_mb=''${FSEVENTSD_GUARD_RESTART_MB:-2048}
    cpu_percent=''${FSEVENTSD_GUARD_CPU_PERCENT:-80}
    cpu_minutes=''${FSEVENTSD_GUARD_CPU_MINUTES:-10}
    max_restarts_per_day=12
    keep_evidence=30
    max_evidence_mb=2048
    min_free_mb=10240
    state=${stateDir}
    evidence=${evidenceDir}

    say() { logger -t fseventsd-guard "$*"; }
    # Every command that can stall gets a deadline, then KILL 5 s later, so one
    # stuck diagnostic can never stop the next minute's run (launchd skips
    # intervals while a run is still going).
    t() { local secs=$1; shift; ${pkgs.coreutils}/bin/timeout -k 5 "$secs" "$@"; }

    mkdir -p "$state" "$evidence" || exit 1

    pid=$(t 10 pgrep -x fseventsd | head -n 1)
    [[ -n "$pid" ]] || exit 0
    # A pid alone can be reused; the pid plus its start time cannot.
    started=$(t 10 ps -o lstart= -p "$pid")
    [[ -n "$started" ]] || exit 0
    same_process() {
      [[ "$(t 5 ps -o lstart= -p "$pid" 2>/dev/null)" == "$started" ]] \
        && [[ "$(t 5 ps -o comm= -p "$pid" 2>/dev/null)" == *fseventsd ]]
    }

    # "fseventsd [377]: 64-bit    Footprint: 137 MB (16384 bytes per page)"
    footprint_of() {
      t 30 footprint -p "$1" 2>/dev/null | awk '
        match($0, /Footprint: [0-9.]+ [KMGT]?B/) {
          split(substr($0, RSTART + 11, RLENGTH - 11), f, " ")
          m = (f[2] == "KB") ? 1 / 1024 : (f[2] == "MB") ? 1 : (f[2] == "GB") ? 1024 : (f[2] == "TB") ? 1048576 : 1 / 1048576
          printf "%d\n", f[1] * m
          exit
        }'
    }
    footprint_mb=$(footprint_of "$pid")
    if [[ -z "$footprint_mb" ]]; then
      say "could not read the footprint of fseventsd pid $pid"
      exit 1
    fi

    # ps prints cumulative CPU as [[H:]M]M:SS.ss.
    cpu_seconds=$(t 10 ps -o time= -p "$pid" | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; printf "%d\n", s }')
    [[ -n "$cpu_seconds" ]] || exit 1
    now=$(date +%s)

    # The hot streak counts consecutive one-minute samples of the same process;
    # a gap over 90 s (a missed minute, a slow capture, sleep) starts it again.
    cpu_share=0
    hot=0
    if [[ -f "$state/last" ]] && read -r last_pid last_started last_now last_cpu last_hot < "$state/last" \
      && [[ "$last_pid" == "$pid" && "$last_started" == "''${started// /_}" ]] && (( now > last_now )); then
      cpu_share=$(( (cpu_seconds - last_cpu) * 100 / (now - last_now) ))
      if (( cpu_share >= cpu_percent && now - last_now <= 90 )); then hot=$(( last_hot + 1 )); fi
    fi
    echo "$pid ''${started// /_} $now $cpu_seconds $hot" > "$state/last"
    echo "$(date '+%F %T') pid=$pid footprint_mb=$footprint_mb cpu_percent=$cpu_share hot_minutes=$hot" >> "$state/samples.log"

    capture_due() {
      [[ ! -f "$state/last-capture" ]] || (( $(date +%s) - $(stat -f %m "$state/last-capture") >= 3600 ))
    }

    # Prune first, then write only with room for one whole capture: at most
    # 2 GB of evidence, and never below 10 GB free on the volume. A capture is
    # about 0.5 MB at normal size; the log is capped at 200 MB before gzip, and
    # every other output is a fixed-size summary or a 5 s sample.
    capture_mb=256
    capture() {
      ls -1d "$evidence"/*/ 2>/dev/null | sort -r | tail -n +"$keep_evidence" | while read -r old; do
        rm -r "$old"
      done
      local used free oldest
      used=$(du -sm "$evidence" | awk '{print $1}')
      while [[ -n "$used" ]] && (( used + capture_mb > max_evidence_mb )); do
        oldest=$(ls -1d "$evidence"/*/ 2>/dev/null | sort | head -n 1)
        [[ -n "$oldest" ]] || break
        rm -r "$oldest"
        used=$(du -sm "$evidence" | awk '{print $1}')
      done
      free=$(df -m "$evidence" | awk 'NR == 2 {print $4}')
      if [[ -z "$used" || -z "$free" ]] || (( used + capture_mb > max_evidence_mb || free < min_free_mb + capture_mb )); then
        say "not saving evidence: ''${used:-?} MB kept, ''${free:-?} MB free"
        return
      fi
      touch "$state/last-capture"
      local dir
      dir="$evidence/$(date +%Y%m%d-%H%M%S)-$1"
      mkdir -p "$dir" || return
      t 30 footprint -p "$pid" > "$dir/footprint.txt" 2>&1
      t 60 vmmap --summary "$pid" > "$dir/vmmap-summary.txt" 2>&1
      t 90 heap -s "$pid" > "$dir/heap.txt" 2>&1
      t 30 sample "$pid" 5 -mayDie -file "$dir/sample.txt" > /dev/null 2>&1
      t 30 lsmp -p "$pid" > "$dir/lsmp.txt" 2>&1
      t 30 ps -axo pid,ppid,etime,time,rss,comm > "$dir/processes.txt" 2>&1
      t 90 log show --last 2h --style compact \
        --predicate 'process == "fseventsd"' 2>/dev/null | head -c 200000000 | gzip > "$dir/fseventsd-log.txt.gz"
      t 30 ls -laT /System/Volumes/Data/.fseventsd > "$dir/disklog-data.txt" 2>&1
      tail -n 180 "$state/samples.log" > "$dir/samples.txt"
      say "saved evidence in $dir (footprint $footprint_mb MB, cpu $cpu_share%, $1)"
    }

    if (( footprint_mb >= restart_mb )); then
      if capture_due; then capture "restart"; fi

      # The capture can take minutes: measure again before deciding, and check
      # identity right before the signal.
      footprint_mb=$(footprint_of "$pid")
      if [[ -z "$footprint_mb" ]] || (( footprint_mb < restart_mb )); then
        say "fseventsd pid $pid is at ''${footprint_mb:-?} MB now; not restarting"
        exit 0
      fi

      # Count and record the restart at the moment it happens; if the history
      # cannot be read or written, do not restart (fail closed).
      now=$(date +%s)
      if ! touch "$state/restarts" \
        || ! recent=$(awk -v since=$(( now - 86400 )) '$1 >= since' "$state/restarts" | wc -l | tr -d ' '); then
        say "cannot read the restart history; not restarting fseventsd at $footprint_mb MB"
        exit 1
      fi
      if (( recent >= max_restarts_per_day )); then
        say "fseventsd at $footprint_mb MB, but $recent restarts in 24 h already; not restarting"
        exit 1
      fi
      if ! echo "$now" >> "$state/restarts"; then
        say "cannot record the restart; not restarting fseventsd at $footprint_mb MB"
        exit 1
      fi

      if ! same_process; then
        say "fseventsd pid $pid exited before the restart; not signalling"
        exit 0
      fi
      kill -TERM "$pid"
      # KILL 15 s after TERM, measured from TERM, whatever the checks cost.
      deadline=$(( SECONDS + 15 ))
      while (( SECONDS < deadline )) && same_process; do
        sleep 1
      done
      if same_process; then kill -KILL "$pid"; fi
      new=""
      for _ in $(seq 1 15); do
        sleep 1
        new=$(t 10 pgrep -x fseventsd | head -n 1)
        [[ -n "$new" ]] && break
      done
      say "restarted fseventsd at $footprint_mb MB: pid $pid -> ''${new:-none yet}"
      rm -f "$state/last"
      exit 0
    fi

    if (( footprint_mb >= warn_mb || hot >= cpu_minutes )) && capture_due; then
      capture "warn"
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
