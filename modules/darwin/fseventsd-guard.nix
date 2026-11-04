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
  # Past restartMB it restarts the daemon before requesting evidence (launchd
  # respawns it). `launchctl kickstart -k` is refused under SIP, so it sends
  # TERM, then KILL. Long-running FSEvents clients do not re-register after a
  # restart; Claude Code falls back to polling its settings, other watchers
  # need their process restarted.
  stateDir = "/var/db/fseventsd-guard";
  evidenceDir = "/var/log/fseventsd-guard";
  guardSeconds = 55;

  common = ''
    set -uo pipefail
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    umask 077

    state=${stateDir}
    evidence=${evidenceDir}
    # Observed with ps -axo pid,uid,comm on 2026-11-04: uid 0, this exact path.
    daemon=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/FSEvents.framework/Versions/A/Support/fseventsd

    # Inner deadlines stay in the outer timeout's process group, so its hard
    # KILL also reaches diagnostics and pipeline children. No shell strings.
    t() { local secs=$1; shift; ${pkgs.coreutils}/bin/timeout --foreground -k 1 "$secs" "$@"; }
    say() { t 1 logger -t fseventsd-guard "$*" || :; }
    discover() {
      t 2 ps -axo pid=,uid=,comm= | t 2 awk -v daemon="$daemon" '$2 == 0 && $3 == daemon { print $1; exit }'
    }
    identify() {
      # comm must be last: macOS ps truncates it when another column follows.
      identity=$(t 2 ps -o uid=,lstart=,comm= -p "$pid") || return 1
      read -r uid weekday month day clock year executable <<< "$identity"
      started="$weekday $month $day $clock $year"
      [[ "$uid" == 0 && "$executable" == "$daemon" && -n "$started" ]]
    }
    same_process() {
      local current
      current=$(t 2 ps -o uid=,lstart=,comm= -p "$pid" 2>/dev/null) || return 1
      [[ "$current" == "$identity" ]]
    }
  '';

  guard = pkgs.writeShellScript "fseventsd-guard" ''
    ${common}
    warn_mb=''${FSEVENTSD_GUARD_WARN_MB:-512}
    restart_mb=''${FSEVENTSD_GUARD_RESTART_MB:-2048}
    cpu_percent=''${FSEVENTSD_GUARD_CPU_PERCENT:-80}
    cpu_minutes=''${FSEVENTSD_GUARD_CPU_MINUTES:-10}
    max_restarts_per_day=12
    # Leave a second for startup and 32 s for the bounded history commit,
    # identity checks, TERM, the 15 s grace period, KILL, and scheduling margin.
    run_deadline=$(( ${toString guardSeconds} - 1 ))
    restart_time_left() { (( SECONDS + 32 < run_deadline )); }

    t 2 mkdir -p "$state" || exit 1
    pid=$(discover)
    [[ -n "$pid" ]] || exit 0
    identify || exit 0

    # "fseventsd [377]: 64-bit    Footprint: 137 MB (16384 bytes per page)"
    footprint_of() {
      t 10 footprint -p "$1" 2>/dev/null | t 10 awk '
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
    cpu_seconds=$(t 2 ps -o time= -p "$pid" | t 2 awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; printf "%d\n", s }')
    [[ -n "$cpu_seconds" ]] || exit 1
    now=$(t 1 date +%s) || exit 1

    # The hot streak counts consecutive one-minute samples of the same process;
    # a gap over 90 s (a missed minute or sleep) starts it again.
    cpu_share=0
    hot=0
    if [[ -f "$state/last" ]] && previous=$(t 1 head -n 1 "$state/last") \
      && read -r last_pid last_started last_now last_cpu last_hot <<< "$previous" \
      && [[ "$last_pid" == "$pid" && "$last_started" == "''${started// /_}" ]] && (( now > last_now )); then
      cpu_share=$(( (cpu_seconds - last_cpu) * 100 / (now - last_now) ))
      if (( cpu_share >= cpu_percent && now - last_now <= 90 )); then hot=$(( last_hot + 1 )); fi
    fi
    restarted=0
    record_sample() {
      # Best effort, after the restart decision and signals. tee opens the
      # files inside its deadline; a shell redirection would open them first.
      if (( ! restarted )); then
        printf '%s\n' "$pid ''${started// /_} $now $cpu_seconds $hot" \
          | t 1 tee "$state/last" > /dev/null || :
      fi
      printf '%s\n' "$(t 1 date '+%F %T') pid=$pid footprint_mb=$footprint_mb cpu_percent=$cpu_share hot_minutes=$hot" \
        | t 1 tee -a "$state/samples.log" > /dev/null || :
    }
    trap record_sample EXIT

    request_capture() {
      # Only a small atomic request crosses jobs. No evidence I/O in this job;
      # launchd schedules its separately bounded worker even after we exit.
      echo "$pid ''${started// /_} $now $footprint_mb $cpu_share $1" > "$state/capture-request.tmp" \
        && t 1 mv -f "$state/capture-request.tmp" "$state/capture-request"
    }

    if (( footprint_mb >= restart_mb )); then
      if ! restart_time_left; then
        say "not enough time for a complete restart; retrying next minute"
        exit 0
      fi
      # Count and record the restart at the moment it happens; if the history
      # cannot be read or written, do not restart (fail closed).
      now=$(t 1 date +%s) || exit 1
      if ! t 1 touch "$state/restarts" \
        || [[ ! -f "$state/restarts" ]] \
        || ! { t 2 awk -v since=$(( now - 86400 )) '
          $0 !~ /^[0-9]+$/ { exit 1 }
          $1 >= since { print $0 }' "$state/restarts" \
          | t 2 tee "$state/restarts.tmp" > /dev/null; } \
        || ! recent=$(t 1 awk 'END { print NR + 0 }' "$state/restarts.tmp"); then
        say "cannot read the restart history; not restarting fseventsd at $footprint_mb MB"
        exit 1
      fi
      if (( recent >= max_restarts_per_day )); then
        say "fseventsd at $footprint_mb MB, but $recent restarts in 24 h already; not restarting"
        exit 1
      fi
      # awk terminates every validated record with a newline, including an
      # unterminated last input line. Append only to that normalized temp file,
      # then replace the history atomically; never concatenate timestamps.
      if ! printf '%s\n' "$now" | t 1 tee -a "$state/restarts.tmp" > /dev/null; then
        say "cannot record the restart; not restarting fseventsd at $footprint_mb MB"
        exit 1
      fi

      # Recheck before committing a restart record as well as before signalling.
      if ! same_process; then
        say "fseventsd pid $pid exited before recording the restart"
        exit 0
      fi
      if ! restart_time_left; then
        say "not enough time to commit and complete a restart; retrying next minute"
        exit 0
      fi
      if ! t 1 ${pkgs.coreutils}/bin/mv -fT -- "$state/restarts.tmp" "$state/restarts"; then
        say "cannot commit the restart history; not restarting fseventsd"
        exit 1
      fi
      if ! same_process; then
        say "fseventsd pid $pid exited before the restart; not signalling"
        exit 0
      fi
      # PID reuse in this millisecond check-to-signal window is accepted:
      # macOS allocates PIDs sequentially, so reuse requires wrapping the whole
      # PID space. proc_signal_with_audittoken would need a compiled helper;
      # deliberately not built here.
      t 1 /bin/kill -TERM "$pid" || exit 1
      # KILL 15 s after TERM, measured from TERM, whatever the checks cost.
      deadline=$(( SECONDS + 15 ))
      while (( SECONDS < deadline )) && same_process; do
        t 2 sleep 1 || :
      done
      if same_process; then t 1 /bin/kill -KILL "$pid"; fi
      restarted=1
      new=$(discover)
      say "restarted fseventsd at $footprint_mb MB: pid $pid -> ''${new:-none yet}"
      t 1 rm -f "$state/last"
      request_capture restart
      exit 0
    fi

    if (( footprint_mb >= warn_mb || hot >= cpu_minutes )); then
      request_capture warn
    fi
  '';

  evidence = pkgs.writeShellScript "fseventsd-guard-evidence" ''
    ${common}
    keep_evidence=30
    max_evidence_mb=2048
    min_free_mb=10240
    capture_mb=256
    file_kib=16384

    # Reserve bytes before opening each output. RLIMIT_FSIZE (Bash's ulimit -f
    # uses KiB) applies in the writer, including sample's own -file writes;
    # head alone cannot bound those. Reserve 1 MiB for directory metadata.
    # The sum of all file limits is <=255 MiB, even if every writer fills it.
    # Disable core dumps so a size-limit signal cannot create another output.
    ulimit -c 0
    remaining_kib=$(( (capture_mb - 1) * 1024 ))
    reserve_file() {
      (( remaining_kib > 0 )) || return 1
      limit_kib=$file_kib
      if (( limit_kib > remaining_kib )); then limit_kib=$remaining_kib; fi
      remaining_kib=$(( remaining_kib - limit_kib ))
    }
    save() {
      local file=$1 secs=$2
      shift 2
      reserve_file || return 1
      ( ulimit -f "$limit_kib" || exit 1; t "$secs" "$@" ) > "$dir/$file" 2>&1
    }
    save_sample() {
      reserve_file || return 1
      ( ulimit -f "$limit_kib" || exit 1
        t 30 sample "$pid" 5 -mayDie -file "$dir/sample.txt"
      ) > /dev/null 2>&1
    }
    compressed_log() {
      # Leave 1% plus 1 KiB for gzip's worst-case expansion and stream headers.
      # RLIMIT_FSIZE remains a backstop, not the normal way to stop gzip: a
      # size-limit signal would leave an invalid stream (oversized-input probe).
      local input_bytes=$(( limit_kib * 1024 * 99 / 100 - 1024 ))
      (( input_bytes > 0 )) || return 1
      t 90 log show --last 2h --style compact \
        --predicate 'process == "fseventsd"' 2>/dev/null \
        | t 90 head -c "$input_bytes" | t 90 gzip
    }
    usage_mb() {
      t 5 du -sm "$evidence" | t 5 awk '{print $1}'
    }
    capture_directory() {
      local name=''${1#"$evidence/"}
      [[ "$1" == "$evidence/"* && "$name" != */* && ! -L "$1" && -d "$1" \
        && "$name" =~ ^[0-9]{8}-[0-9]{6}-(warn|restart)$ ]]
    }
    prune() {
      local old used
      local -a dirs=()
      # Enumerate immediate entries without a trailing slash: globbing */ also
      # accepts directory symlinks, and rm on link/ follows the target on macOS.
      # Unknown entries still count in du, but are never deletion candidates.
      shopt -s nullglob
      for old in "$evidence"/*; do
        if capture_directory "$old"; then dirs+=("$old"); fi
      done
      used=$(usage_mb) || return 1
      [[ "$used" =~ ^[0-9]+$ ]] || return 1
      for old in "''${dirs[@]}"; do
        if (( ''${#dirs[@]} < keep_evidence && used + capture_mb <= max_evidence_mb )); then break; fi
        capture_directory "$old" || return 1
        # No trailing slash even after validation: replacement with a symlink
        # between the check and rm can only unlink the link, not its target.
        t 5 rm -r -- "$old" || return 1
        dirs=("''${dirs[@]:1}")
        used=$(usage_mb) || return 1
        [[ "$used" =~ ^[0-9]+$ ]] || return 1
      done
      (( used + capture_mb <= max_evidence_mb ))
    }
    # A request may wait for a worker run already in progress (300 s), the next
    # 60 s interval, and this run's own bounded preparation (<300 s): 900 s
    # covers that, and stays far below the one-hour capture allowance, so an
    # old request cannot take the slot from a fresh runaway.
    request_max_age=900
    capture() {
      local captured free now requested_started requested_now footprint_mb cpu_share reason
      [[ -f "$state/capture-request" ]] || return 0
      read -r pid requested_started requested_now footprint_mb cpu_share reason < "$state/capture-request" || return 1
      [[ "$requested_now" =~ ^[0-9]+$ && "$reason" =~ ^(warn|restart)$ ]] || return 1
      now=$(t 1 date +%s) || return 1
      (( now >= requested_now && now - requested_now <= request_max_age )) || return 0
      if [[ -f "$state/last-capture" ]]; then
        captured=$(t 1 stat -f %m "$state/last-capture") || return 1
        (( requested_now > captured && now - captured >= 3600 )) || return 0
      fi
      t 2 mkdir -p "$evidence" || return 1
      prune || { say "could not prune evidence; not saving evidence"; return 1; }
      free=$(t 5 df -m "$evidence" | t 5 awk 'NR == 2 {print $4}') || return 1
      [[ "$free" =~ ^[0-9]+$ ]] && (( free >= min_free_mb + capture_mb )) || return 1
      now=$(t 1 date +%s) || return 1
      (( now >= requested_now && now - requested_now <= request_max_age )) || return 0
      t 1 touch "$state/last-capture" || return 1
      dir="$evidence/$(t 1 date +%Y%m%d-%H%M%S)-$reason"
      t 2 mkdir "$dir" || return 1

      # A restart request describes the old process. Never inspect a reused
      # PID: once it exits, only collect the system log and sampling history.
      if identify && [[ "''${started// /_}" == "$requested_started" ]]; then
        save footprint.txt 30 footprint -p "$pid"
        save vmmap-summary.txt 60 vmmap --summary "$pid"
        save heap.txt 90 heap -s "$pid"
        save_sample
        save lsmp.txt 30 lsmp -p "$pid"
      fi
      save processes.txt 10 ps -axo pid,ppid,etime,time,rss,comm
      # A function runs in a subshell under the same file limit; each command
      # in this pipeline has its own deadline as well as the worker deadline.
      reserve_file || return 1
      ( ulimit -f "$limit_kib" || exit 1; compressed_log ) > "$dir/fseventsd-log.txt.gz" 2>/dev/null
      save disklog-data.txt 10 ls -laT /System/Volumes/Data/.fseventsd
      save samples.txt 5 tail -n 180 "$state/samples.log"
      say "saved bounded evidence in $dir (footprint $footprint_mb MB, cpu $cpu_share%, $reason)"
    }
    capture
  '';
in
{
  launchd.daemons.fseventsd-guard = {
    # A whole-run deadline also bounds shell redirections and state I/O. Use
    # KILL for the whole group: TERM can end the shell before timeout's later
    # KILL, leaving a TERM-ignoring diagnostic behind (verified with a stub).
    # Direct arguments avoid nix-darwin's unbounded wait4path command wrapper.
    # This job never waits for the separately supervised evidence job.
    serviceConfig = {
      ProgramArguments = [
        "${pkgs.coreutils}/bin/timeout"
        "-s"
        "KILL"
        "-k"
        "1"
        (toString guardSeconds)
        "${guard}"
      ];
      StartInterval = 60;
      RunAtLoad = true;
      ProcessType = "Background";
    };
  };
  launchd.daemons.fseventsd-guard-evidence = {
    serviceConfig = {
      ProgramArguments = [
        "${pkgs.coreutils}/bin/timeout"
        "-s"
        "KILL"
        "-k"
        "5"
        "300"
        "${evidence}"
      ];
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
