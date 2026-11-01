{ lib, ... }:
let
  # System V shared memory, which every PostgreSQL cluster on this Mac needs:
  # each running cluster holds one small segment (PostgreSQL 17 asks for 56
  # bytes as its interlock; the buffers themselves are mmap'd), and `initdb`
  # takes one more while it bootstraps. macOS allows 32 segments machine-wide
  # (`kern.sysv.shmmni`, measured 2026-11-01). One repository's database gate
  # starts six throwaway clusters at once, so two or three gates together, or
  # the self-hosted Actions runners beside a local gate, used them all, and every
  # further cluster died in `initdb` with "could not create shared memory
  # segment: No space left on device" (shmget, size=56; four concurrent gates,
  # 2026-11-01, with 15 segments already in use).
  #
  # The count, the per-process count and the total change; the per-segment
  # size limits stay at macOS's defaults, which PostgreSQL's 56-byte segment
  # never nears. `shmall` is the total in pages and every segment takes at
  # least one, so it must grow with the count.
  # XNU takes these five values together, which is how PostgreSQL's macOS
  # kernel-resources documentation sets them.
  shm = {
    "kern.sysv.shmmax" = 4194304;
    "kern.sysv.shmmin" = 1;
    "kern.sysv.shmmni" = 1024;
    "kern.sysv.shmseg" = 32;
    "kern.sysv.shmall" = 4096;
  };
  lines = lib.mapAttrsToList (name: value: "${name}=${toString value}") shm;
in
{
  # Read by launchd at boot, before anything creates a segment.
  environment.etc."sysctl.conf".text = lib.concatLines lines;

  # On a running Mac XNU accepts the total and the per-process count but keeps
  # the segment count until the next restart (measured 2026-11-01: after
  # `sysctl -w`, shmall and shmseg changed, shmmni stayed 32). Try anyway, and
  # only while the running count differs from the declared one.
  system.activationScripts.postActivation.text = ''
    if [[ "$(/usr/sbin/sysctl -n kern.sysv.shmmni)" != ${toString shm."kern.sysv.shmmni"} ]]; then
      if /usr/sbin/sysctl -w ${lib.concatStringsSep " " lines} >/dev/null 2>&1; then
        echo >&2 "System V shared memory limits applied"
      else
        echo >&2 "System V shared memory limits take effect at the next restart (in use: $(/usr/sbin/sysctl -n kern.sysv.shmmni) segments allowed)"
      fi
    fi
  '';
}
