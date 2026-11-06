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
# Another public repository (local.nix publicProjects). nix-config is stood in
# for by $nixcfg: it holds the check, the hooks and local.nix. The second
# repository has none of them; scripts/install-hooks.sh points its
# core.hooksPath at $nixcfg's hooks, and the guard must inspect the repository
# it runs in, not the one it lives in.
physical=$(cd "$work_dir" && pwd -P) # the paths below must equal git's own
nixcfg="$physical/nix-config"
other="$physical/second-public"
mkdir -p "$nixcfg/ai/hooks" "$nixcfg/scripts" "$work_dir/bin"
cp "$repository/scripts/check-private-names.sh" "$repository/scripts/install-hooks.sh" "$nixcfg/scripts/"
cp -R "$repository/scripts/hooks" "$nixcfg/scripts/hooks"
cat > "$nixcfg/ai/hooks/nix-only-guard-test.py" <<'PY'
import os
with open(os.environ["NIX_STEPS_MARKER"], "a") as marker:
    marker.write("guard-test\n")
PY
# nix-config's pre-commit formats with `nix fmt`; stand in for that one command.
cat > "$work_dir/bin/nix" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == fmt ]]; then
  echo fmt >> "$NIX_STEPS_MARKER"
  exit 0
fi
exec "$REAL_NIX" "$@"
SH
chmod +x "$work_dir/bin/nix"
marker="$work_dir/nix-config-steps"
real_nix=$(command -v nix)

cat > "$work_dir/local-public.nix" <<NIX
{
  privateTerms = [ "fixture-private-name" ];
  projects = {
    nixconfig = "$nixcfg";
    second-public = "$other";
    hidden-project = "$physical/hidden-project";
    not-checked-out = "$physical/not-here";
  };
  publicProjects = [ "second-public" "not-checked-out" ];
}
NIX
# The same machine before publicProjects existed, with nix-config checked out
# elsewhere than this guard.
cat > "$work_dir/local-private.nix" <<NIX
{
  privateTerms = [ "fixture-private-name" ];
  projects = {
    nixconfig = "$physical/elsewhere";
    second-public = "$other";
  };
}
NIX
local_nix="$work_dir/local-public.nix"

for repo in "$nixcfg" "$other"; do
  git init -q -b main "$repo"
  git -C "$repo" config user.name "Fixture User"
  git -C "$repo" config user.email "fixture@example.invalid"
done
git -C "$nixcfg" add .
printf '%s\n' "fixture-private-name" > "$nixcfg/leaky.txt"
git -C "$nixcfg" add leaky.txt
git -C "$nixcfg" commit -q -m "nix-config stand-in, tree already naming a private term"
printf 'clean\n' > "$other/initial.txt"
git -C "$other" add initial.txt
git -C "$other" commit -q -m "clean initial commit"
git -C "$other" switch -q -c leak
printf '%s\n' "fixture-private-name" > "$other/leaked.txt"
git -C "$other" add leaked.txt
git -C "$other" commit -q -m "leak"
leak_sha=$(git -C "$other" rev-parse HEAD)
git -C "$other" switch -q main

check_in() { # <repo> <local.nix> <check args...> → status; output in check-output
  (cd "$1" && NIX_CONFIG_LOCAL="$2" "$nixcfg/scripts/check-private-names.sh" "${@:3}") >"$work_dir/check-output" 2>&1
}
expect_check() { # <blocked|passed> <case> <repo> <local.nix> <check args...>; NEEDLE= names the refusal
  local result=passed
  check_in "$3" "$4" "${@:5}" || result=blocked
  if [[ "$result" != "$1" ]]; then
    echo "error: $2 was $result, expected $1:" >&2
    cat "$work_dir/check-output" >&2
    exit 1
  fi
  if [[ "$1" == blocked ]] && ! grep -F -- "${NEEDLE:-fixture-private-name}" "$work_dir/check-output" >/dev/null; then
    echo "error: $2 was blocked for the wrong reason:" >&2
    cat "$work_dir/check-output" >&2
    exit 1
  fi
}

# --tree and --commits inspect the repository they run in. $nixcfg's tree names
# a private term; the second repository's does not.
expect_check passed "the tree of a second public repository (nix-config's tree names a private term)" \
  "$other" "$local_nix" --tree
expect_check blocked "the tree of nix-config itself" "$nixcfg" "$local_nix" --tree
expect_check blocked "a private term added by a commit of the second public repository" \
  "$other" "$local_nix" --commits "$leak_sha" --not main
expect_check passed "the second public repository's clean history" "$other" "$local_nix" --commits main

# The pre-push hook finds the check beside itself: the second repository has
# no scripts/ of its own.
zero=0000000000000000000000000000000000000000
push_from_other() { # <local ref> <sha> → the pre-push hook's status
  (
    cd "$other"
    printf 'refs/heads/%s %s refs/heads/%s %s\n' "$1" "$2" "$1" "$zero" |
      NIX_CONFIG_LOCAL="$local_nix" "$nixcfg/scripts/hooks/pre-push" >"$work_dir/push-output" 2>&1
  )
}
if push_from_other leak "$leak_sha"; then
  echo "error: a push of a private term from a second public repository was not rejected" >&2
  exit 1
fi
grep -F 'fixture-private-name' "$work_dir/push-output" >/dev/null
if ! push_from_other main "$(git -C "$other" rev-parse main)"; then
  echo "error: a clean push from a second public repository was rejected:" >&2
  cat "$work_dir/push-output" >&2
  exit 1
fi

# The installer wires each public checkout that exists to nix-config's hooks and
# skips one that is not on disk; running it again changes nothing.
install_hooks() { NIX_CONFIG_LOCAL="$1" "$nixcfg/scripts/install-hooks.sh" >"$work_dir/install-output" 2>&1; }
if ! install_hooks "$local_nix"; then
  echo "error: install-hooks.sh failed with a public project that is not checked out:" >&2
  cat "$work_dir/install-output" >&2
  exit 1
fi
# nix-config keeps the relative path, so each of its worktrees runs its own
# branch's hooks; another public repository has none of its own, so it gets
# the canonical checkout's absolute path.
for expected in "$nixcfg=scripts/hooks" "$other=$nixcfg/scripts/hooks"; do
  repo=${expected%%=*}
  if [[ "$(git -C "$repo" config --local --get core.hooksPath)" != "${expected#*=}" ]]; then
    echo "error: install-hooks.sh did not point $repo at ${expected#*=}:" >&2
    cat "$work_dir/install-output" >&2
    exit 1
  fi
done
if ! grep -F 'not-here' "$work_dir/install-output" >/dev/null; then
  echo "error: install-hooks.sh did not say it skipped the checkout that is not on disk:" >&2
  cat "$work_dir/install-output" >&2
  exit 1
fi
install_hooks "$local_nix"
if grep -F 'now run from' "$work_dir/install-output" >/dev/null; then
  echo "error: install-hooks.sh is not idempotent:" >&2
  cat "$work_dir/install-output" >&2
  exit 1
fi
if ! install_hooks "$work_dir/absent.nix" || ! grep -F 'only nix-config' "$work_dir/install-output" >/dev/null; then
  echo "error: install-hooks.sh did not fall back to nix-config alone without a local.nix:" >&2
  cat "$work_dir/install-output" >&2
  exit 1
fi

# The pre-commit hook, run by git itself in both repositories.
commit_in() { # <repo> <message> → git commit's status; output in commit-output
  PATH="$work_dir/bin:$PATH" NIX_STEPS_MARKER="$marker" REAL_NIX="$real_nix" NIX_CONFIG_LOCAL="$local_nix" \
    git -C "$1" commit -q -m "$2" >"$work_dir/commit-output" 2>&1
}
expect_commit() { # <blocked|passed> <case> <repo> <file> <content> [<text the refusal names>]
  printf '%s\n' "$5" > "$3/$4"
  git -C "$3" add "$4"
  local result=passed
  commit_in "$3" "$2" || result=blocked
  if [[ "$result" != "$1" ]]; then
    echo "error: $2 was $result, expected $1:" >&2
    cat "$work_dir/commit-output" >&2
    exit 1
  fi
  if [[ "$1" == blocked ]]; then
    if ! grep -F -- "${6:-$5}" "$work_dir/commit-output" >/dev/null; then
      echo "error: $2 was blocked for the wrong reason:" >&2
      cat "$work_dir/commit-output" >&2
      exit 1
    fi
    git -C "$3" reset -q
  fi
}

expect_commit blocked "a private term staged in a second public repository" \
  "$other" leak.txt "fixture-private-name"
expect_commit blocked "a private project's name staged in a second public repository" \
  "$other" hidden.txt "work on hidden-project" hidden-project
expect_commit blocked "the second public repository's own checkout path" \
  "$other" path.txt "$other" "$other"
expect_commit passed "the second public repository's own project name" \
  "$other" own-name.txt "the second-public project"
if [[ -e "$marker" ]]; then
  echo "error: nix-config's own pre-commit steps ran in a second public repository:" >&2
  cat "$marker" >&2
  exit 1
fi

# nix-config keeps those steps, in its checkout and in its linked worktrees.
expect_commit passed "a clean commit in nix-config" "$nixcfg" clean.txt "clean"
git -C "$nixcfg" worktree add -q -b nixcfg-linked "$physical/worktree-a" >/dev/null 2>&1
expect_commit passed "a clean commit in a linked worktree of nix-config" "$physical/worktree-a" linked.txt "clean"
if [[ "$(grep -c guard-test "$marker")" != 2 || "$(grep -c fmt "$marker")" != 2 ]]; then
  echo "error: nix-config's pre-commit steps did not run for both commits:" >&2
  cat "$marker" >&2
  exit 1
fi

# Git exports GIT_DIR to a hook run from a linked worktree, which must not make
# the second repository look like nix-config, nor its checkout path public.
git -C "$other" worktree add -q -b other-linked "$physical/worktree-b" >/dev/null 2>&1
expect_commit blocked "the checkout path staged in a linked worktree of a second public repository" \
  "$physical/worktree-b" path.txt "$other" "$other"
expect_commit passed "a clean commit in a linked worktree of a second public repository" \
  "$physical/worktree-b" clean.txt "clean"
if [[ "$(grep -c guard-test "$marker")" != 2 ]]; then
  echo "error: nix-config's pre-commit steps ran in a linked worktree of a second public repository:" >&2
  cat "$marker" >&2
  exit 1
fi

# Without publicProjects only nix-config is public, as before: the second
# repository's name is private, and the name nixconfig is public even when its
# checkout is not the one holding this guard.
printf '%s\n' "the second-public project, again" > "$other/second-name.txt"
git -C "$other" add second-name.txt
NEEDLE=second-public expect_check blocked "the second project's name, absent from publicProjects" \
  "$other" "$work_dir/local-private.nix" --staged
git -C "$other" reset -q
printf '%s\n' "the nixconfig project" > "$other/nixconfig-name.txt"
git -C "$other" add nixconfig-name.txt
expect_check passed "the name nixconfig" "$other" "$work_dir/local-private.nix" --staged
git -C "$other" reset -q

echo "check-private-names range tests passed"
