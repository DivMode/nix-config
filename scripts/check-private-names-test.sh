#!/usr/bin/env bash

# Regression test for the private-name check's multi-argument rev-list range.
# The protected branch already contains a private-name fixture, so a clean
# feature commit must pass while a new feature commit adding that name fails.

set -euo pipefail

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
echo "check-private-names range tests passed"
