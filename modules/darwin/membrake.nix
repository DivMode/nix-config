{
  inputs,
  lib,
  local,
  pkgs,
  ...
}:
let
  membrake = inputs.membrake.packages.${pkgs.stdenv.hostPlatform.system}.default;

  # The self-hosted runners' account (./github-runners.nix), present only when
  # local.nix declares runners.
  runnerUser = lib.optional ((local.githubRunners or null) != null) "_github-runner";

  # membrake writes its own rotated samples.tsv and events.log under
  # /var/log/membrake and records frozen jobs under /var/db/membrake; this file
  # only catches what it prints to stdout and stderr.
  log = "/var/log/membrake.log";
in
{
  # The memory brake. On 2026-11-05 about ten agent sessions and the four CI
  # runners ran 31 tsc, 8 tsgolint and 92 node processes at once on this 96 GB
  # Mac. The JetsamEvent reports in /Library/Logs/DiagnosticReports from
  # 13:31, 14:06 and 14:32 HST show the kernel killing 416, then 2,745
  # processes, every one in jetsam band 0 with reason `low-swap` (system
  # daemons: secd, cloudd, accountsd, homed, ...), while all 131
  # tsc/tsgolint/node sat in band 180 untouched; the owner had to restart.
  # The CPU clamps (cpu-lock, the runners' taskpolicy) order the CPU, not
  # memory. membrake freezes (SIGSTOP) the newest agent job when memory is
  # tight, freezes every agent job when the Mac heads for the cliff, resumes
  # them one at a time when memory recovers, and kills only at the cliff; the
  # README at https://github.com/DivMode/membrake has the policy and evidence.
  #
  # Root, because it must see and signal every user's jobs. The runner account
  # is protected: its jobs are never frozen and are killed only when nothing
  # else is left.
  launchd.daemons.membrake.serviceConfig = {
    ProgramArguments = [
      "${membrake}/bin/membrake"
      "run"
    ]
    ++ lib.concatMap (user: [
      "--protect-user"
      user
    ]) runnerUser;
    RunAtLoad = true;
    KeepAlive = true;
    # Its sampling must keep running when the machine is swapping; this is the
    # class of a foreground app. membrake also lifts itself out of jetsam band
    # 0 at start (the band the kernel kills first under swap shortage).
    ProcessType = "Interactive";
    # On SIGTERM membrake resumes every job it froze before exiting.
    ExitTimeOut = 20;
    StandardOutPath = log;
    StandardErrorPath = log;
  };

  # On every user's PATH, so an agent whose command stalls can run
  # `membrake status` to see whether it is frozen (the global instructions
  # tell it to, before killing or rerunning the command).
  environment.systemPackages = [ membrake ];

  # Rotated by newsyslog like ./log-rotation.nix's entries: by size only, keep
  # 3 archives of 1 MB, no signal (`N`), no compression (launchd keeps the file
  # open).
  environment.etc."newsyslog.d/membrake.conf".text = ''
    ${log}  root:wheel  644  3  1024  *  N
  '';
}
