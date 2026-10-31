{
  lib,
  local,
  pkgs,
  ...
}:
let
  # Keeps each registered project checkout (projects.nix) at GitHub's default
  # branch. Work happens in worktrees and merges on GitHub, and some
  # repositories' workflows never pull the main checkout afterwards, so it
  # fell months behind. `just` reads the justfile of the checkout it runs in:
  # one such checkout still ran recipes removed 67 commits earlier, whose
  # top-level backticks called the 1Password CLI and raised Touch ID prompts
  # on every `just wt` (2026-10-31).
  #
  # Only a fast-forward of a checkout that is on its default branch with no
  # uncommitted changes to tracked files. Anything else (another branch, a
  # detached HEAD, local commits, uncommitted changes) is left alone and
  # logged while it is behind, so no work is ever moved or discarded. Git
  # refuses a fast-forward that would overwrite an untracked file.
  projects = lib.attrValues (local.projects or { });

  sync = pkgs.writeShellScript "sync-project-checkouts" ''
    # No `set -e`: one project's failure must not stop the others.
    for repository in ${lib.escapeShellArgs projects}; do
      say() { echo "$(date -u +%FT%TZ) $repository: $1"; }
      root=$(git -C "$repository" rev-parse --show-toplevel 2>/dev/null)
      if [ "$root" != "$repository" ]; then
        say "not a Git checkout root; skipped"
        continue
      fi
      default=$(git -C "$repository" symbolic-ref --quiet --short refs/remotes/origin/HEAD) || default=origin/main
      branch=''${default#origin/}
      # An explicit destination, so a narrowed remote.origin.fetch cannot
      # leave the ref stale.
      if ! git -C "$repository" fetch --quiet origin "+refs/heads/$branch:refs/remotes/origin/$branch"; then
        say "fetching $branch failed"
        continue
      fi
      git -C "$repository" merge-base --is-ancestor "origin/$branch" HEAD && continue
      behind=$(git -C "$repository" rev-list --count "HEAD..origin/$branch")
      current=$(git -C "$repository" symbolic-ref --quiet --short HEAD) || current="a detached HEAD"
      changes=$(git -C "$repository" status --porcelain --untracked-files=no)
      if [ "$current" != "$branch" ]; then
        say "$behind behind origin/$branch, on $current; left alone"
      elif ! git -C "$repository" merge-base --is-ancestor HEAD "origin/$branch"; then
        say "$behind behind origin/$branch with local commits; left alone"
      elif [ -n "$changes" ]; then
        say "$behind behind origin/$branch with uncommitted changes; left alone"
      elif git -C "$repository" merge --ff-only --quiet "origin/$branch"; then
        say "fast-forwarded $behind commits to $(git -C "$repository" rev-parse --short HEAD)"
      else
        say "fast-forward of $behind commits failed"
      fi
    done
  '';
in
{
  # launchd's bare environment has no Nix profile on PATH; a non-interactive
  # zsh reads /etc/zshenv and ~/.zshenv, as scheduled-commands.nix does. Git
  # reaches GitHub through the declared Connect transport (core.sshCommand).
  launchd.agents.sync-project-checkouts = {
    enable = true;
    config = {
      ProgramArguments = [
        "/bin/zsh"
        "-c"
        "exec ${sync}"
      ];
      RunAtLoad = true;
      StartInterval = 900;
      ProcessType = "Background";
      LowPriorityIO = true;
      StandardOutPath = "${local.homeDirectory}/Library/Logs/sync-project-checkouts.log";
      StandardErrorPath = "${local.homeDirectory}/Library/Logs/sync-project-checkouts.log";
    };
  };
}
