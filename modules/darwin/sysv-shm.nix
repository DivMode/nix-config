{ lib, pkgs, ... }:
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
  # never nears. `shmall` is the total in pages (16 KiB here) and every segment
  # takes at least one, so it grows with the count: 4096 pages is 64 MiB, of
  # which 1024 minimal segments use 16 MiB. All five are set, as PostgreSQL's
  # macOS kernel-resources documentation recommends; XNU validates each write
  # on its own.
  shm = {
    "kern.sysv.shmmax" = 4194304;
    "kern.sysv.shmmin" = 1;
    "kern.sysv.shmmni" = 1024;
    "kern.sysv.shmseg" = 32;
    "kern.sysv.shmall" = 4096;
  };

  marker = "# Managed by nix-config (modules/darwin/sysv-shm.nix); activation rewrites this file.";
  conf = pkgs.writeText "sysctl.conf" (
    # The marker goes last: how launchd's boot-time reader treats a comment
    # line is unverified, and it must not stand in front of the values.
    lib.concatLines (lib.mapAttrsToList (name: value: "${name}=${toString value}") shm ++ [ marker ])
  );
in
{
  # launchd reads /etc/sysctl.conf early in boot, before the encrypted /nix
  # volume is unlocked (org.nixos.darwin-store), so it must be a regular file
  # in /etc, not environment.etc's link into the store, which launchd would
  # silently find missing. Activation copies it there and refuses to replace a
  # sysctl.conf this module did not write.
  #
  # XNU fixes `shmmni` when the segment table is first allocated, so on a
  # running Mac the count waits for the next restart (measured 2026-11-01:
  # shmall and shmseg changed at once, shmmni stayed 32). The other values are
  # applied now, and any failure other than that one is reported.
  system.activationScripts.postActivation.text = ''
    sysctlConf=/etc/sysctl.conf
    if [[ -L "$sysctlConf" && "$(readlink "$sysctlConf")" == /etc/static/sysctl.conf ]]; then
      rm "$sysctlConf"
    fi
    if [[ -e "$sysctlConf" ]] && ! grep -qxF ${lib.escapeShellArg marker} "$sysctlConf"; then
      echo >&2 "error: $sysctlConf exists and was not written by nix-config; merge it into modules/darwin/sysv-shm.nix and remove it"
      exit 1
    fi
    if ! cmp -s ${conf} "$sysctlConf"; then
      install -m 0644 -o root -g wheel ${conf} "$sysctlConf"
    fi
    ${lib.concatStrings (
      lib.mapAttrsToList (name: value: ''
        if [[ "$(/usr/sbin/sysctl -n ${name})" != ${toString value} ]]; then
          if ! sysctlError=$(/usr/sbin/sysctl -w ${name}=${toString value} 2>&1 >/dev/null); then
            ${
              if name == "kern.sysv.shmmni" then
                ''echo >&2 "${name}=${toString value} takes effect at the next restart (now $(/usr/sbin/sysctl -n ${name}))"''
              else
                ''echo >&2 "warning: could not set ${name}=${toString value}: $sysctlError"''
            }
          fi
        fi
      '') shm
    )}
  '';
}
