#!/usr/bin/env bash

# Regression test for the private-name check's multi-argument rev-list range.
# The protected branch already contains a private-name fixture, so a clean
# feature commit must pass while a new feature commit adding that name fails.

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

cat > "$fixture/local.nix" <<'EOF'
{ privateTerms = [ "fixture-private-name" ]; }
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
