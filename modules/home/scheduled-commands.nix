{
  lib,
  local,
  pkgs,
  ...
}:
let
  # Recurring commands a project runs from its own checkout, such as a daily
  # check against production. Which projects and commands are machine identity,
  # so they come from the ignored local.nix, keyed by a job name:
  #
  #   scheduledCommands.<job> = {
  #     repository = "/abs/path/to/canonical/checkout";
  #     worktree = "/abs/path/to/dedicated/worktree";
  #     branch = "main";
  #     commands = [ [ "bun" "install" "--frozen-lockfile" ] [ "bun" "run" "check" ] ];
  #     hour = 6;
  #     minute = 30;
  #   };
  #
  # Each run fetches `branch` in the canonical checkout, moves the dedicated
  # worktree (created on first run) to `origin/<branch>`, and runs the commands
  # there in order, stopping at the first failure. The worktree belongs to the
  # job: a dirty one, or a path that is not a worktree of that repository, fails
  # the run instead of being overwritten.
  jobs = local.scheduledCommands or { };

  absolute = path: builtins.isString path && lib.hasPrefix "/" path;
  invalid = lib.filterAttrs (
    name: job:
    builtins.match "[a-z][a-z0-9-]*" name == null
    || !(absolute (job.repository or null))
    || !(absolute (job.worktree or null))
    || (job.commands or [ ]) == [ ]
  ) jobs;

  runner =
    name: job:
    pkgs.writeShellScript "scheduled-${name}" ''
      set -euo pipefail
      repository=${lib.escapeShellArg job.repository}
      worktree=${lib.escapeShellArg job.worktree}
      branch=${lib.escapeShellArg (job.branch or "main")}
      fail() {
        echo "$(date -u +%FT%TZ) ${name}: $1" >&2
        exit 1
      }
      echo "$(date -u +%FT%TZ) ${name}: start"
      # Each Git answer is its own assignment: a failure inside a `[ ... ]`
      # comparison does not stop `set -e`, and two failures compare equal.
      root=$(git -C "$repository" rev-parse --show-toplevel)
      [ "$root" = "$repository" ] || fail "$repository is not a Git root"
      common=$(git -C "$repository" rev-parse --path-format=absolute --git-common-dir)
      # An explicit destination, so a narrowed remote.origin.fetch cannot leave
      # the ref stale.
      target="refs/remotes/origin/$branch"
      git -C "$repository" fetch --quiet origin "+refs/heads/$branch:$target"
      if [ ! -e "$worktree" ]; then
        git -C "$repository" worktree add --quiet --detach "$worktree" "$target"
      fi
      root=$(git -C "$worktree" rev-parse --show-toplevel)
      [ "$root" = "$worktree" ] || fail "$worktree is not a Git root"
      worktreeCommon=$(git -C "$worktree" rev-parse --path-format=absolute --git-common-dir)
      [ "$worktreeCommon" = "$common" ] || fail "$worktree is not a worktree of $repository"
      changes=$(git -C "$worktree" status --porcelain --untracked-files=all)
      [ -z "$changes" ] || fail "$worktree has local changes"
      # Ignored files are not in that status; never let a newly tracked path
      # replace one.
      git -C "$worktree" checkout --quiet --no-overwrite-ignore --detach "$target"
      cd "$worktree"
      head=$(git rev-parse HEAD)
      echo "$(date -u +%FT%TZ) ${name}: at $head"
      ${lib.concatMapStringsSep "\n" (command: lib.escapeShellArgs command) job.commands}
      echo "$(date -u +%FT%TZ) ${name}: done"
    '';
in
{
  assertions = [
    {
      assertion = invalid == { };
      message = "local.scheduledCommands entries need a lowercase job name, absolute repository and worktree paths, and at least one command: ${lib.concatStringsSep ", " (builtins.attrNames invalid)}";
    }
  ];

  # launchd starts agents with a bare environment: no Nix profile on PATH, none
  # of Home Manager's session variables (TMPDIR, the relocated caches in
  # caches.nix) and no mise shims. A non-interactive
  # zsh reads /etc/zshenv (nix-darwin's PATH) and ~/.zshenv (the session
  # variables and the mise shims, development.nix), which is the environment an
  # agent's own shell runs these commands in.
  launchd.agents = lib.mapAttrs' (
    name: job:
    lib.nameValuePair "scheduled-${name}" {
      enable = true;
      config = {
        ProgramArguments = [
          "/bin/zsh"
          "-c"
          "exec ${runner name job}"
        ];
        StartCalendarInterval = [
          {
            Hour = job.hour or 6;
            Minute = job.minute or 0;
          }
        ];
        StandardOutPath = "${local.homeDirectory}/Library/Logs/scheduled-${name}.log";
        StandardErrorPath = "${local.homeDirectory}/Library/Logs/scheduled-${name}.log";
      };
    }
  ) jobs;
}
