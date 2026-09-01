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

# Keep the pre-update state so the summary below reports what actually changed
# rather than what was requested.
claudePin="modules/home/claude-code-pin.json"
lockBefore="$(mktemp)"
pinBefore="$(mktemp)"
trap 'rm -f "$lockBefore" "$pinBefore"' EXIT
cp flake.lock "$lockBefore"
cp "$claudePin" "$pinBefore"

if (( ${#inputs[@]} == 0 )); then
  echo "==> Updating every input"
  nix flake update
else
  echo "==> Updating: ${inputs[*]}"
  nix flake update "${inputs[@]}"
fi

# ── Claude Code: pin straight to Anthropic's latest release ─────────────────
# The version is not taken from the llm-agents input, whose packaging
# automation trails Anthropic by hours-to-a-day (measured 2026-09-01: it
# packaged 2.1.252 while upstream had published 2.1.257 that morning).
# modules/home/development.nix builds llm-agents' recipe against the version
# and hash pinned in $claudePin; this refreshes that pin from the SAME
# endpoints llm-agents' own updater reads — Anthropic's `latest` pointer and
# the per-version manifest whose checksums are official. Following the pointer
# also follows it DOWN: Anthropic yanks bad releases by repointing it.
#
# Only on a full update or an explicit llm-agents update — asking for just the
# Homebrew casks must not move a coding agent. A refresh that cannot reach the
# bucket warns and keeps the current pin: a stale-but-working version beats an
# aborted update, and the staleness is printed rather than silent.
refreshClaudePin=false
if (( ${#inputs[@]} == 0 )); then
  refreshClaudePin=true
else
  for input in "${inputs[@]}"; do
    [[ "$input" == "llm-agents" ]] && refreshClaudePin=true
  done
fi

if [[ "$refreshClaudePin" == true ]]; then
  claudeBucket="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
  if claudeLatest="$(curl -fsSL --max-time 15 "$claudeBucket/latest")" \
    && [[ "$claudeLatest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    && claudeManifest="$(curl -fsSL --max-time 15 "$claudeBucket/$claudeLatest/manifest.json")"; then
    toSri() {
      nix hash convert --hash-algo sha256 --to sri \
        "$(jq -er --arg p "$1" '.platforms[$p].checksum' <<<"$claudeManifest")"
    }
    jq -n \
      --arg version "$claudeLatest" \
      --arg darwinArm "$(toSri darwin-arm64)" \
      --arg linuxArm "$(toSri linux-arm64)" \
      --arg linuxX64 "$(toSri linux-x64)" \
      '{
        version: $version,
        hashes: {
          "aarch64-darwin": $darwinArm,
          "aarch64-linux": $linuxArm,
          "x86_64-linux": $linuxX64
        }
      }' > "$claudePin"
  else
    echo "    warning: could not read Anthropic's release bucket; claude-code stays at $(jq -r .version "$claudePin")" >&2
  fi
fi

if /usr/bin/cmp -s "$lockBefore" flake.lock && /usr/bin/cmp -s "$pinBefore" "$claudePin"; then
  echo "==> Already current; nothing moved"
  exit 0
fi

echo
echo "==> Inputs that moved"
git --no-pager diff --stat -- flake.lock || true
if ! /usr/bin/cmp -s "$pinBefore" "$claudePin"; then
  echo "    claude-code: $(jq -r .version "$pinBefore") -> $(jq -r .version "$claudePin")"
fi

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
echo "==> Landing the version bump on main"

if git diff --quiet HEAD -- flake.lock "$claudePin"; then
  echo "    flake.lock and $claudePin already match HEAD; nothing to land"
  exit 0
fi

# Refuse to automate a commit while unrelated tracked changes sit in the tree:
# branch-switching would drag them along, and an automated commit must never
# sweep in work it does not own. Untracked files are fine — committing only
# the two version files cannot pick them up.
if ! git diff --quiet HEAD -- . ":(exclude)flake.lock" ":(exclude)$claudePin"; then
  echo "error: tracked changes besides flake.lock and $claudePin are in the tree." >&2
  echo "The system IS activated, but the version bump is NOT landed." >&2
  echo "Commit or stash the other changes, then land the bump via a PR." >&2
  exit 1
fi

startBranch="$(git branch --show-current)"
if [[ -z "$startBranch" ]]; then
  echo "error: detached HEAD; not landing automatically." >&2
  echo "The system IS activated. Land flake.lock via a PR from a branch." >&2
  exit 1
fi

# What moved, for the PR body. Best-effort: jq's absence already only
# costs the staleness report above, and it only costs the nice listing here.
moved="flake inputs"
if command -v jq >/dev/null 2>&1; then
  moved="$(git show HEAD:flake.lock | jq -r --slurpfile new flake.lock '
    $new[0].nodes as $n | .nodes as $o
    | [ $n | keys[] | select(. != "root")
        | select(($n[.].locked.rev // $n[.].locked.narHash // "")
                 != ($o[.].locked.rev // $o[.].locked.narHash // "")) ]
    | join(", ")' || echo "flake inputs")"
  if ! git diff --quiet HEAD -- "$claudePin"; then
    moved="claude-code $(git show "HEAD:$claudePin" | jq -r .version) -> $(jq -r .version "$claudePin")${moved:+; }${moved}"
  fi
fi

branch="chore/flake-lock-$(date +%Y%m%d-%H%M%S)"
git switch -c "$branch"
git add flake.lock "$claudePin"
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
