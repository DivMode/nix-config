#!/usr/bin/env bash
#
# Move the pinned inputs forward, then build and activate the result.
#
# Versions in this repository are pinned in flake.lock, so nothing on the Mac
# advances on its own. That is deliberate — activation is reproducible, and a
# version change arrives as a reviewable diff — but it means updating is an
# explicit act. This is that act, as one command.
#
# You never edit a version by hand. `nix flake update` rewrites the lock; this
# script prints exactly what moved, builds it, activates, and then lands the
# lock bump on main (branch, PR, squash-merge) so the machine and the
# repository do not drift apart.
#
#   ./scripts/update.sh                       # every input
#   ./scripts/update.sh homebrew-cask         # just the Homebrew casks
#   ./scripts/update.sh --dry-run             # update the lock, do not activate
#
# Most declared casks carry Homebrew's `auto_updates` flag and update themselves,
# so they are unaffected either way. The ones that depend on this are the casks
# with no self-updater — currently claude-code and 1password-cli.

set -euo pipefail

repository="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository"

if [[ ! -f local.nix ]]; then
  echo "error: $repository/local.nix is missing; see docs/setup/new-mac.md" >&2
  exit 1
fi

export NIX_CONFIG_LOCAL="$repository/local.nix"

dryRun=false
inputs=()
for argument in "$@"; do
  case "$argument" in
    --dry-run) dryRun=true ;;
    -*)
      echo "error: unknown option $argument" >&2
      exit 1
      ;;
    *) inputs+=("$argument") ;;
  esac
done

host="${HOST:-example-mac}"

# ── Tag-pinned inputs: staleness notice ─────────────────────────────────────
# Inputs pinned to a release tag (gcx-src, herdr) are deliberately NOT moved
# by `nix flake update` — a new version arrives by editing the tag in
# flake.nix, as a reviewable decision. The gcx 1.0→1.1 output-shape change
# (2026-08-16) is why adoption stays manual: it silently inverted a health
# check's verdict, and a deliberate update surfaced that within minutes
# instead of at 3am. Detection, though, should be automatic — a pin nobody
# remembers is how a tool goes stale for six months. So every update run
# reports each tag pin against the latest upstream release, one line per pin,
# and prints failures rather than skipping silently: a check that cannot run
# must not read as "everything current".
echo "==> Tag-pinned inputs (moved by editing flake.nix, not by this script)"
if ! command -v jq >/dev/null 2>&1; then
  echo "    warning: jq not found — cannot check tag-pin staleness" >&2
else
  while IFS=$'\t' read -r name owner repo ref via; do
    release_json=""
    if command -v gh >/dev/null 2>&1; then
      release_json="$(gh api "repos/${owner}/${repo}/releases/latest" 2>/dev/null || true)"
    fi
    if [[ -z "$release_json" ]]; then
      release_json="$(curl -fsSL --max-time 10 \
        "https://api.github.com/repos/${owner}/${repo}/releases/latest" 2>/dev/null || true)"
    fi
    latest="$(jq -r '.tag_name // empty' <<<"$release_json" 2>/dev/null || true)"
    if [[ -z "$latest" ]]; then
      echo "    ${name}: pinned ${ref} — could not determine latest release of ${owner}/${repo} (offline, rate-limited, or no releases)" >&2
    elif [[ "$latest" == "$ref" ]]; then
      echo "    ${name}: ${ref} (current)"
    elif [[ "$via" == "direct" ]]; then
      echo "    ${name}: pinned ${ref}, upstream has ${latest} — to adopt, edit the tag in flake.nix"
    else
      # A transitive pin is not ours to edit: it moves when ITS owner bumps
      # the tag and this lock re-locks that input. brew-src (nix-homebrew's
      # tested pin of the brew program) is the expected case here.
      echo "    ${name}: pinned ${ref} by the ${via} input, upstream has ${latest} — adopts automatically via './scripts/update.sh ${via}' once ${via} bumps it"
    fi
  done < <(jq -r '
    .nodes as $nodes
    | ($nodes.root.inputs | [to_entries[].value]) as $rootKeys
    | $nodes | to_entries[]
    | select(.key != "root"
             and .value.original.type == "github"
             and ((.value.original.ref // "") | test("^v?[0-9]")))
    | .key as $k
    | (if ($rootKeys | index($k)) then "direct" else
         ([$nodes | to_entries[]
           | select(.key != "root"
                    and ((.value.inputs // {}) | [to_entries[].value] | flatten | index($k)))
           | .key] | first // "unknown")
       end) as $via
    | [$k, .value.original.owner, .value.original.repo, .value.original.ref, $via]
    | @tsv' flake.lock)
fi
echo

# Keep the pre-update lock so the summary below reports what actually changed
# rather than what was requested.
lockBefore="$(mktemp)"
trap 'rm -f "$lockBefore"' EXIT
cp flake.lock "$lockBefore"

if (( ${#inputs[@]} == 0 )); then
  echo "==> Updating every input"
  nix flake update
else
  echo "==> Updating: ${inputs[*]}"
  nix flake update "${inputs[@]}"
fi

if /usr/bin/cmp -s "$lockBefore" flake.lock; then
  echo "==> Already current; nothing moved"
  exit 0
fi

echo
echo "==> Inputs that moved"
git --no-pager diff --stat -- flake.lock || true

# Everything from here to the final activation is a pure build: a failure leaves
# the Mac untouched and the lock change still sitting in the working tree for
# inspection.
echo
echo "==> Checking"
nix flake check --impure

echo "==> Building $host"
nix build --no-link --impure ".#darwinConfigurations.${host}.system"

if [[ "$dryRun" == true ]]; then
  echo
  echo "==> Built successfully; not activating (--dry-run)"
  echo "    Review the flake.lock diff, then run ./scripts/rebuild.sh"
  exit 0
fi

echo
echo "==> Activating"
"$repository/scripts/rebuild.sh" "$host"

# ── Land the lock bump ──────────────────────────────────────────────────────
# A lock bump that only lives in this working tree is a machine that no longer
# matches its own repository: every later nix invocation warns about a dirty
# tree, and a wiped machine would rebuild yesterday's versions. By this point
# the change has earned its commit — checked, built, and activated above, which
# is the same activate-before-commit bar AGENTS.md sets for any change — so
# land it the only way changes land here: a branch, a PR, and a squash-merge.
# Direct pushes to main are not allowed, and that rule is not this script's to
# bend.
#
# Deliberately absent on --dry-run, whose whole point is leaving the diff in
# the tree for inspection.
echo
echo "==> Landing the flake.lock bump on main"

if git diff --quiet HEAD -- flake.lock; then
  echo "    flake.lock already matches HEAD; nothing to land"
  exit 0
fi

# Refuse to automate a commit while unrelated tracked changes sit in the tree:
# branch-switching would drag them along, and an automated commit must never
# sweep in work it does not own. Untracked files are fine — committing only
# flake.lock cannot pick them up.
if ! git diff --quiet HEAD -- . ':(exclude)flake.lock'; then
  echo "error: tracked changes besides flake.lock are in the tree." >&2
  echo "The system IS activated, but the lock bump is NOT landed." >&2
  echo "Commit or stash the other changes, then land flake.lock via a PR." >&2
  exit 1
fi

startBranch="$(git branch --show-current)"
if [[ -z "$startBranch" ]]; then
  echo "error: detached HEAD; not landing automatically." >&2
  echo "The system IS activated. Land flake.lock via a PR from a branch." >&2
  exit 1
fi

# Which inputs moved, for the PR body. Best-effort: jq's absence already only
# costs the staleness report above, and it only costs the nice listing here.
moved="flake inputs"
if command -v jq >/dev/null 2>&1; then
  moved="$(git show HEAD:flake.lock | jq -r --slurpfile new flake.lock '
    $new[0].nodes as $n | .nodes as $o
    | [ $n | keys[] | select(. != "root")
        | select(($n[.].locked.rev // $n[.].locked.narHash // "")
                 != ($o[.].locked.rev // $o[.].locked.narHash // "")) ]
    | join(", ")' || echo "flake inputs")"
fi

branch="chore/flake-lock-$(date +%Y%m%d-%H%M%S)"
git switch -c "$branch"
git add flake.lock
git commit -m "chore(flake): update inputs" -m "Moved: ${moved}

Landed by scripts/update.sh after nix flake check, a full system build,
and activation on the machine that ran the update."
git push -u origin "$branch"
gh pr create \
  --title "chore(flake): update inputs" \
  --body "Moved: ${moved}

Automated by \`scripts/update.sh\`: the lock was updated, \`nix flake check\` passed, the system built, and the result was activated before this commit was created."
# --delete-branch also checks the default branch out afterwards and pulls it,
# so a run started from main ends on an up-to-date main with a clean tree.
gh pr merge --squash --delete-branch

if [[ "$startBranch" != "$(git branch --show-current)" ]] \
  && git show-ref --quiet "refs/heads/$startBranch"; then
  git switch "$startBranch"
fi

echo
echo "==> Landed: $(git log --oneline -1 origin/main 2>/dev/null || true)"
