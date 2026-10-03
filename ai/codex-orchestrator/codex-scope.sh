# Post-run scope check for a delegated Codex worker. Packaged by
# modules/home/ai with writeShellApplication (strict mode, shellcheck, git on
# PATH), so this file carries no shebang of its own.
#
#   codex-scope snapshot <worktree>
#     Print a tree id for the worktree's full content: tracked files as they
#     sit on disk (staged or not) plus untracked, non-ignored files. Uses a
#     throwaway index, so the real index and working tree are untouched; it
#     does write blob objects into the repository's object store.
#
#   codex-scope check <worktree> <baseline-tree> -- <pathspec>...
#     Snapshot again and list every path whose content differs from the
#     baseline, each marked in-scope or OUT-OF-SCOPE against the git
#     pathspecs. Exit 0 when nothing is out of scope, 1 when something is.
#
# Taking the baseline after the worktree is prepared and before dispatch means
# pre-existing edits are part of the baseline and never attributed to the
# worker. Blind spots: ignored files, anything outside the worktree, and HEAD
# movement (compare HEAD against the recorded head separately).

usage() {
  echo "usage: codex-scope snapshot <worktree>" >&2
  echo "       codex-scope check <worktree> <baseline-tree> -- <pathspec>..." >&2
  exit 2
}

snapshot() {
  local worktree="$1" scratch index
  scratch="$(mktemp -d)"
  index="$scratch/index"
  # Seed from the real index when there is one, so unchanged files keep their
  # stat cache and are not re-hashed.
  cp "$(git -C "$worktree" rev-parse --path-format=absolute --git-path index)" "$index" 2>/dev/null || true
  GIT_INDEX_FILE="$index" git -C "$worktree" add --all -- . >/dev/null
  GIT_INDEX_FILE="$index" git -C "$worktree" write-tree
  rm -rf "$scratch"
}

[[ $# -ge 2 ]] || usage
command="$1"
worktree="$2"
git -C "$worktree" rev-parse --show-toplevel >/dev/null || exit 2
[[ "$(git -C "$worktree" rev-parse --show-toplevel)" == "$(cd "$worktree" && pwd -P)" ]] || {
  echo "codex-scope: $worktree is not a worktree root" >&2
  exit 2
}

case "$command" in
  snapshot)
    [[ $# -eq 2 ]] || usage
    snapshot "$worktree"
    ;;
  check)
    [[ $# -ge 4 && "$3" != "--" && "$4" == "--" ]] || usage
    baseline="$3"
    shift 4
    [[ $# -ge 1 ]] || usage
    git -C "$worktree" cat-file -e "$baseline^{tree}" || exit 2
    current="$(snapshot "$worktree")"

    mapfile -t changed < <(git -C "$worktree" diff --name-only --no-renames "$baseline" "$current")
    mapfile -t allowed < <(git -C "$worktree" diff --name-only --no-renames "$baseline" "$current" -- "$@")

    declare -A inScope=()
    for path in "${allowed[@]}"; do inScope["$path"]=1; done

    outside=0
    for path in "${changed[@]}"; do
      if [[ -n "${inScope[$path]:-}" ]]; then
        echo "in-scope      $path"
      else
        echo "OUT-OF-SCOPE  $path"
        outside=1
      fi
    done
    [[ ${#changed[@]} -gt 0 ]] || echo "no changes since baseline"
    exit "$outside"
    ;;
  *) usage ;;
esac
