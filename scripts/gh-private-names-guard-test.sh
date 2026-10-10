#!/usr/bin/env bash

# Regression test for scripts/gh-private-names-guard.sh, against a stand-in gh
# that records what it was asked to do. Both directions matter: a write to the
# public repository naming a private term must never reach gh, and a write to
# any other repository, or any read, must reach it unchanged — a guard that
# blocks ordinary work gets worked around.

set -euo pipefail

# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars)
unset GH_REPO

repository="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

# The public checkout: the guard and check scripts, a local.nix, an origin.
public="$work_dir/public"
mkdir -p "$public/scripts"
cp "$repository/scripts/check-private-names.sh" "$repository/scripts/gh-private-names-guard.sh" "$public/scripts/"
cat > "$public/local.nix" <<'EOF'
{ privateTerms = [ "fixture-private-name" ]; }
EOF
git -C "$public" init -q -b main
git -C "$public" remote add origin git@github.com:fixture-owner/public-repo.git

private="$work_dir/private"
git init -q -b main "$private"
git -C "$private" remote add origin https://github.com/fixture-owner/private-repo.git

# The stand-in gh writes its arguments and stdin where the test can read them.
calls="$work_dir/calls"
cat > "$work_dir/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$calls"
cat > "$calls.stdin"
EOF
chmod +x "$work_dir/gh"

body_file="$work_dir/body.md"
printf 'Summary\n\nfixture-private-name was involved.\n' > "$body_file"

run() { # <dir> <stdin> gh-args... → guard's exit status; sets $reached
  local dir=$1 input=$2
  shift 2
  rm -f "$calls" "$calls.stdin"
  local status=0
  (
    cd "$dir"
    printf '%s' "$input" |
      GH_GUARD_REAL_GH="$work_dir/gh" GH_GUARD_CHECKOUT="$public" \
        bash "$public/scripts/gh-private-names-guard.sh" "$@" >"$work_dir/output" 2>&1
  ) || status=$?
  reached=false
  [[ -f "$calls" ]] && reached=true
  return "$status"
}
blocked() { # <case> <dir> <stdin> gh-args...
  local name=$1
  shift
  if run "$@" || $reached; then
    echo "error: $name reached gh" >&2
    cat "$work_dir/output" >&2
    exit 1
  fi
  if ! grep -F 'fixture-private-name' "$work_dir/output" >/dev/null; then
    echo "error: $name was blocked for the wrong reason:" >&2
    cat "$work_dir/output" >&2
    exit 1
  fi
}
passed() { # <case> <dir> <stdin> gh-args...
  local name=$1
  shift
  if ! run "$@" || ! $reached; then
    echo "error: $name did not reach gh:" >&2
    cat "$work_dir/output" >&2
    exit 1
  fi
}

leak="fixes the fixture-private-name outage"

blocked "a PR body naming a private term, from the public checkout" \
  "$public" "" pr create --title "fix: guard" --body "$leak"
blocked "a PR title naming a private term" \
  "$public" "" pr edit 3 --title "$leak"
blocked "a body file naming a private term" \
  "$public" "" pr create --title "fix: guard" --body-file "$body_file"
blocked "a body read from stdin naming a private term" \
  "$public" "$leak" issue comment 4 --body-file -
blocked "-R naming the public repository, from elsewhere" \
  "$private" "" issue create -R fixture-owner/Public-Repo --title t --body "$leak"
(
  export GH_REPO=https://github.com/fixture-owner/public-repo
  blocked "GH_REPO naming the public repository" "$work_dir" "" pr comment 5 --body "$leak"
)
blocked "an API write to the public repository" \
  "$work_dir" "" api repos/fixture-owner/public-repo/issues -f "body=$leak"
blocked "an API write with a {owner}/{repo} placeholder in the public checkout" \
  "$public" "" api 'repos/{owner}/{repo}/issues/1/comments' -F "body=@$body_file"

passed "a clean PR body to the public repository" \
  "$public" "" pr create --title "fix: guard" --body "clean text"
passed "a clean body from stdin, which gh must still receive" \
  "$public" "clean stdin body" pr comment 6 --body-file -
if [[ "$(cat "$calls.stdin")" != "clean stdin body" ]]; then
  echo "error: gh did not receive the stdin body the guard read" >&2
  exit 1
fi
passed "a private term in a write to a private repository" \
  "$private" "" pr create --title t --body "$leak"
passed "a private term in a read of the public repository" \
  "$public" "" pr list --search "fixture-private-name"
passed "a private term in an API read of the public repository" \
  "$public" "" api repos/fixture-owner/public-repo/issues -X GET -f "q=$leak"

echo "gh-private-names-guard tests passed"
