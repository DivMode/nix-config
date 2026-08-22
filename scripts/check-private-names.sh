#!/usr/bin/env bash
#
# Refuse to let private names reach this public repository.
#
# This repository is public; `local.nix` is the ignored file that holds
# everything private about the machine — the owner, the host, the private
# project checkouts, the 1Password vault. Nothing stops those names being typed
# into a tracked file by hand, and on 2026-08-14 an audit found fourteen of
# them already committed: a private monorepo named in nine comments across
# three modules, and the vault name hard-coded in two scripts.
#
# So the denylist is not written down here. It is DERIVED from local.nix at run
# time, which means it is always current: add a project to local.nix and it is
# guarded from that moment, with nothing to remember and nothing to sync. The
# list itself never enters a tracked file, because a list of your private names
# in a public repository is the leak it was meant to prevent.
#
#   --staged           check the staged content of a commit (what the pre-commit
#                      hook runs; scans whole staged files, not just the added
#                      lines, so a leak cannot ride along in a file you were
#                      editing anyway)
#   --tree             audit every tracked file in the working tree
#   --commits <rev-list-args...>
#                      check what each commit in the supplied `git rev-list`
#                      arguments ADDS (what the pre-push hook runs)
#
# --commits exists because a pre-commit hook only ever sees the commit being
# made. On 2026-08-14 this script blocked three commits successfully and then
# `git push` carried two OLDER commits — written before the guard existed —
# straight to GitHub with the private monorepo named in eight comment lines. A
# guard on committing is not a guard on publishing. It checks added lines rather
# than whole trees so that commits inheriting a not-yet-scrubbed file from the
# base branch are not all flagged; whole-file coverage is --staged's job.
#
# Exit 0 clean, 1 on a hit or on any condition that makes checking impossible.
# It fails closed on purpose: an unverifiable commit into a public repository
# is the case the guard exists for.

set -euo pipefail

repository="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
git_common_dir="$(git -C "$repository" rev-parse --path-format=absolute --git-common-dir)"
canonical_repository="$(cd "$(dirname "$git_common_dir")" && pwd)"
cd "$repository"

mode="${1:---staged}"
commit_args=("${@:2}")
case "$mode" in
  --staged | --tree) ;;
  --commits)
    if (( ${#commit_args[@]} == 0 )); then
      echo "usage: ${BASH_SOURCE[0]##*/} --commits <rev-list-args...>" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: ${BASH_SOURCE[0]##*/} [--staged|--tree|--commits <range>]" >&2
    exit 1
    ;;
esac

local_file="${NIX_CONFIG_LOCAL:-$repository/local.nix}"
if [[ ! -f "$local_file" ]]; then
  cat >&2 <<EOF
error: cannot check for private names — $local_file is missing.

  This repository is public and the private-name denylist is derived from
  local.nix, so without it nothing can be verified. Restore it first:
  see docs/setup/new-mac.md.
EOF
  exit 1
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
terms_file="$work_dir/terms"

# Every private string this machine knows about, one per line.
#
# `x.y or default` is safe across a missing attribute at any point in the path,
# so an older local.nix without one of these keys narrows the denylist rather
# than failing the commit.
#
# This repository's own checkout is excluded by PATH, not by name. A linked
# worktree has a different root, so its primary checkout is public by
# definition too; matching that project's name case-insensitively would flag
# every `nixConfig.*` option in the tree.
if ! LOCAL_PATH="$local_file" REPO_PATH="$repository" CANONICAL_REPO_PATH="$canonical_repository" nix eval --impure --raw --expr '
  let
    local = import (builtins.toPath (builtins.getEnv "LOCAL_PATH"));
    repository = builtins.getEnv "REPO_PATH";
    canonicalRepository = builtins.getEnv "CANONICAL_REPO_PATH";
    projects = local.projects or { };
    public = builtins.filter (
      name: builtins.elem projects.${name} [ repository canonicalRepository ]
    ) (builtins.attrNames projects);
    privateProjects = builtins.removeAttrs projects public;
    awsVaults = map (profile: profile.vault or "") (
      builtins.attrValues (local.onePassword.awsProfiles or { })
    );
    candidates =
      builtins.attrNames privateProjects
      ++ builtins.attrValues privateProjects
      ++ awsVaults
      ++ [
        (local.user or "")
        (local.hostName or "")
        (local.homeDirectory or "")
        (local.git.name or "")
        (local.git.email or "")
        (local.onePassword.vault or "")
        (local.onePassword.connectHost or "")
      ]
      ++ (local.privateTerms or [ ]);

    # Terms the fields above yield that are NOT actually private.
    #
    # NOTE: this whole expression sits inside a single-quoted shell string, so
    # an apostrophe anywhere in these comments ends that string and breaks the
    # script. Write around it. Measured the hard way on 2026-08-21.
    #
    # The denylist is derived, which is what keeps it current — but derivation
    # cannot tell a generic name like Homelab from the name of a company; both
    # arrive through onePassword.vault. With no way to say which is which, a
    # generic vault name gets guarded as if it were secret, leaving only two
    # ways forward: hard-code nothing, so a wiped Mac must be told its vault by
    # hand, or skip the hook. The guidance at the top of this file rejects the
    # second and calls this exact case a misfire to be fixed in the derivation.
    # This is that fix.
    #
    # Subtracted LAST, so it also clears a term that arrived from several
    # fields at once. Keep it to names that would mean nothing to a stranger
    # reading this public repository — anything that identifies a person,
    # employer, client, host, or private path belongs in privateTerms instead.
    publicTerms = local.publicTerms or [ ];
    isPublic = term: builtins.elem term publicTerms;

    usable = builtins.filter (
      term: builtins.isString term && builtins.stringLength term > 2 && !(isPublic term)
    ) candidates;
    deduplicated = builtins.attrNames (
      builtins.listToAttrs (map (term: { name = term; value = true; }) usable)
    );
  in
  builtins.concatStringsSep "\n" deduplicated
' > "$terms_file" 2>"$work_dir/eval-error"; then
  echo "error: could not read private names from $local_file" >&2
  sed 's/^/  /' "$work_dir/eval-error" >&2
  exit 1
fi

if [[ ! -s "$terms_file" ]]; then
  echo "error: $local_file yielded no private names to check for" >&2
  exit 1
fi

hits=0
report() {
  (( hits == 0 )) && echo "Private names must not enter this public repository:" >&2
  hits=$(( hits + 1 ))
  printf '  %s\n' "$1" >&2
}

if [[ "$mode" == "--commits" ]]; then
  while IFS= read -r commit; do
    [[ -n "$commit" ]] || continue
    subject=$(git log -1 --format='%h %s' "$commit")
    file="?"
    while IFS= read -r line; do
      case "$line" in
        '+++ b/'*)
          file=${line#+++ b/}
          if term=$(printf '%s\n' "$file" | grep -oiF -f "$terms_file" | head -n1) && [[ -n "$term" ]]; then
            report "$subject — adds path \"$file\" containing \"$term\""
          fi
          continue
          ;;
        '+++'* | '+'*) ;;
        *) continue ;;
      esac
      added=${line#+}
      term=$(printf '%s\n' "$added" | grep -oiF -f "$terms_file" | head -n1) || true
      [[ -n "$term" ]] && report "$subject — $file adds \"$term\""
    done < <(git show --format= --unified=0 "$commit")
  done < <(git rev-list --no-merges "${commit_args[@]}")
else
  if [[ "$mode" == "--staged" ]]; then
    files=$(git diff --cached --name-only --diff-filter=ACMR)
  else
    files=$(git ls-files)
  fi

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue

    if term=$(printf '%s\n' "$file" | grep -oiF -f "$terms_file" | head -n1) && [[ -n "$term" ]]; then
      report "$file — path contains \"$term\""
    fi

    if [[ "$mode" == "--staged" ]]; then
      content=$(git show ":$file" 2>/dev/null) || continue
    else
      [[ -f "$file" ]] || continue
      content=$(cat "$file")
    fi

    while IFS= read -r match; do
      [[ -n "$match" ]] || continue
      line_number=${match%%:*}
      line_text=${match#*:}
      term=$(printf '%s\n' "$line_text" | grep -oiF -f "$terms_file" | head -n1)
      report "$file:$line_number — \"$term\""
    done < <(printf '%s\n' "$content" | grep -inIF -f "$terms_file" || true)
  done <<< "$files"
fi

if (( hits > 0 )); then
  cat >&2 <<EOF

$hits occurrence(s). Every name above is derived from local.nix, which is
ignored precisely so these stay off GitHub.

  Comments   — describe the thing generically ("the work monorepo"), or cite
               the evidence without naming the repository.
  Values     — move them into local.nix and read them from there at run time,
               the way scripts/rebuild.sh reads the 1Password vault.
  Misfire    — a term that is genuinely public (this repository's own name)
               belongs outside the denylist; fix the derivation above rather
               than skipping the hook.
EOF
  exit 1
fi

[[ "$mode" == "--tree" ]] && echo "No private names in $(git ls-files | wc -l | tr -d ' ') tracked files."
exit 0
