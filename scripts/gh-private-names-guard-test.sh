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
printf '%s\n' "\${GH_EDITOR:-}" > "$calls.editor"
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

# Ways past the first version, found in review: aliases and commands a list
# of writes did not name, a URL from another checkout, attached short flags,
# GraphQL from anywhere, and a byte that made grep call the text binary.
blocked "gh's own alias pr new" \
  "$public" "" pr new -t x -b "$leak"
blocked "pr revert, which takes a body" \
  "$public" "" pr revert 3 -b "$leak"
blocked "issue develop, which names a branch on GitHub" \
  "$public" "" issue develop 3 --name "$leak"
blocked "a release asset label" \
  "$public" "" release upload v1 "$body_file#$leak"
blocked "a PR URL naming the public repository, from a private checkout" \
  "$private" "" pr comment https://github.com/fixture-owner/public-repo/pull/5 -b "$leak"
blocked "an attached -R" \
  "$private" "" issue create -Rfixture-owner/public-repo -t t -b "$leak"
blocked "an attached -F body file" \
  "$public" "" pr create -t x "-F$body_file"
blocked "an attached api -F field file" \
  "$work_dir" "" api repos/fixture-owner/public-repo/issues "-Fbody=@$body_file"
blocked "a GraphQL mutation from a private checkout" \
  "$private" "" api graphql -f "query=mutation { addComment(input: {subjectId: \"x\", body: \"$leak\"}) { clientMutationId } }"
blocked "an API write that names no repository" \
  "$private" "" api -X POST repositories/123/issues -f "title=$leak"
binary_body="$work_dir/binary.md"
printf 'caf\xe9 %s\n' "$leak" > "$binary_body"
blocked "a body with an invalid UTF-8 byte" \
  "$public" "" pr create -t x --body-file "$binary_body"
if (
  cd "$public" && GH_GUARD_REAL_GH="$work_dir/gh" GH_GUARD_CHECKOUT="$public" \
    bash "$public/scripts/gh-private-names-guard.sh" issue create -t x --editor >/dev/null 2>&1
) || [[ -f "$calls" ]]; then
  echo "error: text from an editor reached gh unchecked" >&2
  exit 1
fi

# Second review: a flag before the action, GraphQL mutations whose query is
# not inline, an editor asked for through combined short flags, and the name
# of an uploaded file.
blocked "-R before the action" \
  "$private" "" pr -R fixture-owner/public-repo create -t x -b "$leak"
blocked "--repo= before the action" \
  "$private" "" issue --repo=fixture-owner/public-repo comment 5 -b "$leak"
blocked "a body flag before the action" \
  "$public" "" pr -b "$leak" create
mutation_json="$work_dir/mutation.json"
printf '{"query":"mutation { addComment(input: {body: \\"%s\\"}) { clientMutationId } }"}\n' "$leak" > "$mutation_json"
blocked "a GraphQL mutation sent with --input" \
  "$private" "" api graphql --input "$mutation_json"
blocked "a GraphQL mutation sent on stdin" \
  "$private" "$(cat "$mutation_json")" api graphql --input -
blocked "a GraphQL query field read from stdin" \
  "$private" "mutation { x(body: \"$leak\") { y } }" api graphql -F query=@-
asset_dir="$work_dir/assets"
mkdir -p "$asset_dir"
printf 'clean asset\n' > "$asset_dir/fixture-private-name.tar"
blocked "an uploaded file whose name is a private term" \
  "$public" "" release upload v1 "$asset_dir/fixture-private-name.tar"
passed "combined short flags asking for an editor" \
  "$public" "" pr create -de -t x
if [[ "$(cat "$calls.editor")" != false ]]; then
  echo "error: gh ran without the failing editor for a checked write" >&2
  exit 1
fi
passed "a private repository's comment linking the public repository" \
  "$private" "" pr comment 5 -b "see https://github.com/fixture-owner/public-repo/pull/3 for the fixture-private-name fix"

# Third review: a write named like a read, a flag hiding the action, and a
# mutation keyword after a comment or a comma.
blocked "label clone, which copies another repository's labels in" \
  "$public" "" label clone "fixture-owner/$leak"
blocked "a value-taking flag before a read-named word" \
  "$public" "" pr -t list create -b "$leak"
blocked "a GraphQL mutation after a comment line" \
  "$private" "" api graphql -f "query=# note
mutation { x(body: \"$leak\") { y } }"
blocked "a GraphQL mutation after a comma" \
  "$private" "" api graphql -f "query=query{a},mutation{x(body: \"$leak\"){y}}"

# A body file's PATH is never posted, and a session's scratch path can name a
# private checkout; only the contents count.
named_dir="$work_dir/fixture-private-name-scratch"
mkdir -p "$named_dir"
printf 'clean body\n' > "$named_dir/body.md"
passed "a clean body file under a path naming a private term" \
  "$public" "" pr create -t x --body-file "$named_dir/body.md"
passed "a GraphQL query (not a mutation) naming a private term, from a private checkout" \
  "$private" "" api graphql -f "query={ repository(owner: \"o\", name: \"fixture-private-name\") { id } }"

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
