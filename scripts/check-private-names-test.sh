#!/usr/bin/env bash

# Regression test for the private-name check's multi-argument rev-list range.
# The protected branch already contains a private-name fixture, so a clean
# feature commit must pass while a new feature commit adding that name fails.
# Also the other text a push publishes: messages, ref names, merges, tags.

set -euo pipefail

# Run from a hook, git exports GIT_DIR, GIT_INDEX_FILE and friends; they would
# point every fixture command below at the real repository.
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars)

repository="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

fixture="$work_dir/repository"
origin="$work_dir/origin.git"
mkdir -p "$fixture/scripts/hooks"
cp "$repository/scripts/check-private-names.sh" "$fixture/scripts/check-private-names.sh"
cp "$repository/scripts/hooks/pre-push" "$fixture/scripts/hooks/pre-push"
chmod +x "$fixture/scripts/check-private-names.sh" "$fixture/scripts/hooks/pre-push"

# The Git identity is in the denylist, as the real derivation puts it there:
# a tag's header carries it, and must not be what blocks the tag.
cat > "$fixture/local.nix" <<'EOF'
{ privateTerms = [ "fixture-private-name" ]; git.name = "Fixture User"; }
EOF

git -C "$fixture" init -b main >/dev/null
git -C "$fixture" config user.name "Fixture User"
git -C "$fixture" config user.email "fixture@example.invalid"

printf '%s\n' "fixture-private-name" > "$fixture/history.txt"
git -C "$fixture" add history.txt
git -C "$fixture" commit -m "protected baseline" >/dev/null

git init --bare "$origin" >/dev/null
git -C "$fixture" remote add origin "$origin"
git -C "$fixture" push -u origin main >/dev/null

git -C "$fixture" switch -c feature >/dev/null
printf '%s\n' "clean feature change" > "$fixture/feature.txt"
git -C "$fixture" add feature.txt
git -C "$fixture" commit -m "clean feature commit" >/dev/null

clean_sha=$(git -C "$fixture" rev-parse HEAD)
zero=0000000000000000000000000000000000000000
if ! (
  cd "$fixture"
  printf 'refs/heads/feature %s refs/heads/feature %s\n' "$clean_sha" "$zero" |
    NIX_CONFIG_LOCAL="$fixture/local.nix" ./scripts/hooks/pre-push >/dev/null
); then
  echo "error: clean commit based on origin/main was rejected" >&2
  exit 1
fi

printf '%s\n' "fixture-private-name" > "$fixture/leak.txt"
git -C "$fixture" add leak.txt
git -C "$fixture" commit -m "private-name commit" >/dev/null

blocked_output="$work_dir/blocked-output"
private_sha=$(git -C "$fixture" rev-parse HEAD)
if (
  cd "$fixture"
  printf 'refs/heads/feature %s refs/heads/feature %s\n' "$private_sha" "$zero" |
    NIX_CONFIG_LOCAL="$fixture/local.nix" ./scripts/hooks/pre-push >"$blocked_output" 2>&1
); then
  echo "error: private-name commit was not rejected" >&2
  exit 1
fi

grep -F 'fixture-private-name' "$blocked_output" >/dev/null

# A diff is not the only text a push publishes: the commit message, the branch
# name, what a merge commit itself changes, and an annotated tag's message all
# reached GitHub past the diff-only check (audit of 2026-10-09).
push_ref() { # <remote ref> <local object> → the pre-push hook's exit status
  (
    cd "$fixture"
    printf 'refs/x %s %s %s\n' "$2" "$1" "$zero" |
      NIX_CONFIG_LOCAL="$fixture/local.nix" ./scripts/hooks/pre-push >"$work_dir/push-output" 2>&1
  )
}
expect() { # <blocked|passed> <case> <remote ref> <local object>
  local result=passed
  push_ref "$3" "$4" || result=blocked
  if [[ "$result" != "$1" ]]; then
    echo "error: $2 was $result, expected $1:" >&2
    cat "$work_dir/push-output" >&2
    exit 1
  fi
  if [[ "$1" == blocked ]] && ! grep -F 'fixture-private-name' "$work_dir/push-output" >/dev/null; then
    echo "error: $2 was blocked for the wrong reason:" >&2
    cat "$work_dir/push-output" >&2
    exit 1
  fi
}
commit_on() { # <branch> <file> <message>
  git -C "$fixture" switch -q -c "$1" main
  printf 'clean %s\n' "$2" > "$fixture/$2"
  git -C "$fixture" add "$2"
  git -C "$fixture" commit -q -m "$3"
  git -C "$fixture" rev-parse HEAD
}

sha=$(commit_on message-leak message.txt "fix: mention fixture-private-name")
expect blocked "a private name in a commit message" refs/heads/message-leak "$sha"

sha=$(commit_on named-branch branch.txt "clean")
expect blocked "a private name in the branch name" refs/heads/fixture-private-name-work "$sha"
expect passed "a clean branch" refs/heads/named-branch "$sha"

commit_on side side.txt "clean side" >/dev/null
commit_on merger merger.txt "clean mainline" >/dev/null
git -C "$fixture" merge -q --no-ff -m "merge side" side
expect passed "a clean merge commit" refs/heads/merger "$(git -C "$fixture" rev-parse HEAD)"
git -C "$fixture" switch -q -c evil-merger HEAD~1
git -C "$fixture" merge -q --no-ff --no-commit side
printf '%s\n' "fixture-private-name" > "$fixture/merge-leak.txt"
git -C "$fixture" add merge-leak.txt
git -C "$fixture" commit -q -m "merge side"
expect blocked "a private name added by a merge commit itself" refs/heads/evil-merger "$(git -C "$fixture" rev-parse HEAD)"

# Merging main into a branch brings its published history along, old leaks
# included; that history is already public and must not block the push. A
# first-parent diff of the merge would show it, the --cc diff does not.
git -C "$fixture" switch -q main
printf '%s\n' "fixture-private-name" > "$fixture/published.txt"
git -C "$fixture" add published.txt
git -C "$fixture" commit -q -m "published before the guard"
git -C "$fixture" push -q origin main
git -C "$fixture" switch -q -c behind main~1
printf 'clean behind\n' > "$fixture/behind.txt"
git -C "$fixture" add behind.txt
git -C "$fixture" commit -q -m "clean behind"
git -C "$fixture" merge -q --no-ff -m "merge main" main
expect passed "a merge bringing in published history that names a private term" refs/heads/behind "$(git -C "$fixture" rev-parse HEAD)"

git -C "$fixture" switch -q main
git -C "$fixture" tag -a -m "release notes naming fixture-private-name" leaky-tag
expect blocked "a private name in a tag message" refs/tags/leaky-tag "$(git -C "$fixture" rev-parse leaky-tag)"
git -C "$fixture" tag -a -m "clean release notes" clean-tag
expect passed "a clean tag (its header carries the Git identity)" refs/tags/clean-tag "$(git -C "$fixture" rev-parse clean-tag)"

# A linked worktree has no local.nix of its own (it is ignored), so the staged
# check must read the main checkout's and still catch a private name there.
git -C "$fixture" add scripts
git -C "$fixture" commit -m "track the guard" >/dev/null
linked="$work_dir/linked"
git -C "$fixture" worktree add -b linked "$linked" >/dev/null 2>&1
printf '%s\n' "fixture-private-name" > "$linked/staged-leak.txt"
git -C "$linked" add staged-leak.txt
linked_output="$work_dir/linked-output"
if (cd "$linked" && ./scripts/check-private-names.sh --staged >"$linked_output" 2>&1); then
  echo "error: private name staged in a linked worktree was not rejected" >&2
  exit 1
fi
if ! grep -F 'fixture-private-name' "$linked_output" >/dev/null; then
  echo "error: linked-worktree check failed for the wrong reason:" >&2
  cat "$linked_output" >&2
  exit 1
fi
echo "check-private-names range tests passed"
