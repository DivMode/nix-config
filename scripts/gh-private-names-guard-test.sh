#!/usr/bin/env bash

# Regression test for scripts/gh-private-names-guard.sh, against a stand-in gh
# that records what it was asked to do. Both directions matter: a write to the
# public repository naming a private term must never reach gh, and a write to
# any other repository, or any read, must reach it unchanged — a guard that
# blocks ordinary work gets worked around. Public repositories are the ones
# GH_GUARD_CHECKOUTS lists (nix-config and local.nix publicProjects).

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

# Which checkouts the wrapper is told are public; a test sets it for its cases.
guard_checkouts="$public"

# The stand-in gh writes its arguments and stdin where the test can read them.
calls="$work_dir/calls"
aliases="$work_dir/aliases"
: > "$aliases"
cat > "$work_dir/gh" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == alias && "\${2:-}" == list ]]; then
  [[ ! -e "$aliases.broken" ]] || exit 1
  cat "$aliases"
  exit 0
fi
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
      GH_GUARD_REAL_GH="$work_dir/gh" GH_GUARD_CHECKOUT="$public" GH_GUARD_CHECKOUTS="$guard_checkouts" \
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
  cd "$public" && GH_GUARD_REAL_GH="$work_dir/gh" GH_GUARD_CHECKOUT="$public" GH_GUARD_CHECKOUTS="$public" \
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

# Fourth review (independent, of the third): flags in front of the command, a
# value that reads as a flag, exported Git variables, aliases, and commands the
# guard cannot name.
#
# gh takes flags before the command, so the command is the first word that is
# not a flag or a flag's value, and a flag's value is never an option.
blocked "-R attached, before the command" \
  "$private" "" -Rfixture-owner/public-repo pr comment 1 -b "$leak"
blocked "--repo= before the command" \
  "$private" "" --repo=fixture-owner/public-repo pr comment 1 -b "$leak"
blocked "-R and its value before the command" \
  "$private" "" -R fixture-owner/public-repo issue create -t t -b "$leak"
passed "a read with -R before the command" \
  "$public" "" -R fixture-owner/public-repo pr list --search "$leak"
passed "a command that only prints the version" \
  "$public" "" --version
blocked "a body that reads as -R, after the real -R" \
  "$private" "" pr comment 1 -R fixture-owner/public-repo -b "-Rfixture-owner/fixture-private-name"
blocked "a title that reads as -R, with the public repository as the checkout" \
  "$public" "" pr create -t "-Rfixture-owner/private-repo" -b "$leak"
blocked "a body that reads as --repo=, with the public repository as the checkout" \
  "$public" "" pr comment 1 -b "--repo=fixture-owner/private-repo $leak"
blocked "-R after a flag of unknown arity, which may have taken it as its value" \
  "$public" "" pr comment 1 --some-new-flag -R fixture-owner/private-repo -b "$leak"
blocked "the public repository named by -R after a flag of unknown arity, from a private checkout" \
  "$private" "" pr comment 1 --some-new-flag -R fixture-owner/public-repo -b "$leak"
passed "-R after a flag that never takes a value, naming a private repository" \
  "$public" "" pr create --draft -R fixture-owner/private-repo -t t -b "$leak"
blocked "-R given twice, the public repository first" \
  "$private" "" pr comment 1 -R fixture-owner/public-repo -R fixture-owner/private-repo -b "$leak"
blocked "-R given twice, the public repository last" \
  "$private" "" pr comment 1 -R fixture-owner/private-repo -R fixture-owner/public-repo -b "$leak"
passed "-R given twice, both private" \
  "$public" "" pr comment 1 -R fixture-owner/private-repo -R fixture-owner/private-repo -b "$leak"

# Git variables exported by whatever launched gh (a hook, another repository's
# shell) must not change which repository a public checkout is.
(
  export GIT_DIR="$private/.git" GIT_WORK_TREE="$private" GIT_COMMON_DIR="$private/.git"
  blocked "-R naming the public repository, under another repository's exported GIT_DIR" \
    "$work_dir" "" issue create -R fixture-owner/public-repo -t t -b "$leak"
)

# An alias expands only inside gh, so its text and its -R are read from
# `gh alias list` (local; no network) before anything is decided.
cat > "$aliases" <<ALIASES
co: pr checkout
quick: pr list
zero: pr comment 1 -b "$leak"
aimed: issue comment 5 -R fixture-owner/public-repo -b "$leak"
shellpost: '!gh pr comment 1 -b "$leak"'
shellclean: '!echo hello'
multiline: |-
    pr comment 1
    -b "$leak"
quoted: 'issue comment 5 -R fixture-owner/public-repo -b "note: $leak"'
ALIASES
blocked "a zero-argument alias whose expansion names a private term" \
  "$public" "" zero
blocked "an alias reached after flags" \
  "$public" "" --hostname github.com zero
blocked "an alias whose expansion aims at the public repository, from a private checkout" \
  "$private" "" aimed
blocked "a shell alias whose text names a private term" \
  "$public" "" shellpost
blocked "an alias whose expansion spans several lines" \
  "$public" "" multiline
blocked "an alias gh prints in quotes (its expansion holds a colon), aimed at the public repository" \
  "$private" "" quoted
passed "a shell alias with clean text" \
  "$public" "" shellclean
passed "an alias for a read" \
  "$public" "" co 5
passed "a zero-argument alias for a read" \
  "$public" "" quick
passed "an alias with a private term, from a private checkout" \
  "$private" "" zero
blocked "a command that is neither built in nor an alias, naming a private term" \
  "$public" "" frobnicate list --search "$leak"
passed "a command that is neither built in nor an alias, from a private checkout" \
  "$private" "" frobnicate list --search "$leak"
touch "$aliases.broken"
if run "$public" "" zero || $reached; then
  echo "error: an alias gh could not list reached gh" >&2
  exit 1
fi
if ! grep -F 'alias' "$work_dir/output" >/dev/null; then
  echo "error: an alias gh could not list was refused for the wrong reason:" >&2
  cat "$work_dir/output" >&2
  exit 1
fi
passed "a built-in command while gh cannot list its aliases" \
  "$public" "" pr list
passed "a flag's value before the command is not taken for the command, while gh cannot list aliases" \
  "$private" "" --hostname github.com pr view 1
rm -f "$aliases.broken"

# A second public repository, declared in local.nix publicProjects. Everything
# above ran with only nix-config listed, which is local.nix without
# publicProjects: a repository that is not listed is private, whatever its name.
second="$work_dir/second-public"
git init -q -b main "$second"
git -C "$second" remote add origin https://github.com/fixture-owner/Second-Public.git

passed "a private term in a write to a repository that is not listed as public" \
  "$private" "" pr create -R fixture-owner/second-public --title t --body "$leak"

guard_checkouts="$public:$second"
blocked "-R naming the second public repository, from a private checkout" \
  "$private" "" pr create -R fixture-owner/second-public --title t --body "$leak"
passed "the same body to a private repository, with two public ones listed" \
  "$private" "" pr create -R fixture-owner/private-repo --title t --body "$leak"
blocked "a write from inside the second public checkout" \
  "$second" "" pr create --title t --body "$leak"
blocked "a PR URL naming the second public repository, from a private checkout" \
  "$private" "" pr comment https://github.com/fixture-owner/second-public/pull/9 -b "$leak"
blocked "an API write to the second public repository" \
  "$work_dir" "" api repos/fixture-owner/second-public/issues -f "body=$leak"
blocked "the first public repository, with two listed" \
  "$private" "" issue create -R fixture-owner/public-repo --title t --body "$leak"
passed "a clean body to the second public repository" \
  "$second" "" pr create --title t --body "clean text"
passed "a read of the second public repository" \
  "$second" "" pr list --search "fixture-private-name"
guard_checkouts="$public"$'\n'"$second"
blocked "the second public repository, listed on a second line" \
  "$private" "" pr create -R fixture-owner/second-public --title t --body "$leak"
guard_checkouts="$public:$second"
rm -f "$calls"
if (
  cd "$second" && GH_GUARD_REAL_GH="$work_dir/gh" GH_GUARD_CHECKOUT="$public" GH_GUARD_CHECKOUTS="$guard_checkouts" \
    bash "$public/scripts/gh-private-names-guard.sh" issue create -t x --editor >/dev/null 2>&1
) || [[ -f "$calls" ]]; then
  echo "error: text from an editor reached gh unchecked in the second public repository" >&2
  exit 1
fi

# A public checkout whose repository cannot be identified refuses every write,
# as the single one always did: nothing then says a command is not aimed at it.
no_origin="$work_dir/no-origin"
git init -q -b main "$no_origin"
for unidentifiable in "$no_origin" "$work_dir/not-on-disk"; do
  guard_checkouts="$public:$unidentifiable"
  if run "$private" "" pr create -R fixture-owner/private-repo --title t --body "clean text" || $reached; then
    echo "error: a write was allowed with an unidentifiable public checkout: $unidentifiable" >&2
    exit 1
  fi
  if ! grep -F 'has no origin remote' "$work_dir/output" >/dev/null; then
    echo "error: an unidentifiable public checkout was refused for the wrong reason:" >&2
    cat "$work_dir/output" >&2
    exit 1
  fi
  passed "a read with an unidentifiable public checkout listed" \
    "$private" "" pr list
done

echo "gh-private-names-guard tests passed"
