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
#   ./scripts/update.sh                       # every input and every pin
#   ./scripts/update.sh homebrew-cask         # just the Homebrew casks
#   ./scripts/update.sh chatgpt               # just the ChatGPT/Codex pin
#   ./scripts/update.sh --dry-run             # update the lock, do not activate
#
# Two versions are pinned by files of this repository's own rather than by the
# lock, and this script refreshes those too: the claude-code pin (from
# Anthropic's release bucket) and the vendored chatgpt cask (re-vendored from
# upstream homebrew-cask). Each is a positional argument like a flake input.
#
# Most declared casks carry Homebrew's `auto_updates` flag and update themselves,
# so they are unaffected either way. The ones that depend on this are the casks
# with no self-updater — currently claude-code and 1password-cli — and chatgpt,
# whose self-updater modules/home/chatgpt.nix deliberately switches off.

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
refreshChatgpt=false
for argument in "$@"; do
  case "$argument" in
    --dry-run) dryRun=true ;;
    -*)
      echo "error: unknown option $argument" >&2
      exit 1
      ;;
    # Not a flake input: the ChatGPT pin is a vendored cask file, refreshed
    # below. Kept out of `inputs` so `nix flake update` never sees it.
    chatgpt) refreshChatgpt=true ;;
    *) inputs+=("$argument") ;;
  esac
done

# No arguments at all means everything: every lock input AND every pin. An
# explicit list moves exactly what it names.
fullUpdate=false
if (( ${#inputs[@]} == 0 )) && [[ "$refreshChatgpt" == false ]]; then
  fullUpdate=true
  refreshChatgpt=true
fi

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

# One line per moved input, old -> new, comparing the given old lock against
# the current flake.lock. Rolling branch inputs (nixpkgs, homebrew-cask, …)
# have no version string, so the commit DATE is printed beside each rev — for
# those inputs the date is the version a human can reason about. A new input
# shows "-" on the old side. Requires jq; callers fall back to a diff stat.
describeLockMoves() {
  jq -r --slurpfile old "$1" '
    def short($r): $r // "" | if length >= 7 then .[0:7] else "-" end;
    def day($t): $t // 0 | todate | .[0:10];
    $old[0].nodes as $o
    | .nodes as $n
    | [ $n | keys[] | select(. != "root") ]
    | map(select(($n[.].locked.rev // $n[.].locked.narHash // "")
                 != (($o[.] // { }).locked.rev // ($o[.] // { }).locked.narHash // "")))
    | .[]
    | "    \(.): \(short(($o[.] // { }).locked.rev)) (\(day(($o[.] // { }).locked.lastModified))) -> \(short($n[.].locked.rev)) (\(day($n[.].locked.lastModified)))"
  ' flake.lock
}

# The version a vendored cask pins: the first `version "…"` line of the cask
# file, the same rule modules/darwin/homebrew.nix applies at evaluation time.
caskVersion() {
  sed -n 's/^ *version "\([^"]*\)".*/\1/p' "$1" | head -n 1
}

# Keep the pre-update state so the summary below reports what actually changed
# rather than what was requested. Every file this script may move is listed in
# versionFiles: the lock, and the two pins this repository keeps itself.
claudePin="modules/home/claude-code-pin.json"
chatgptCask="taps/homebrew-pinned/Casks/chatgpt.rb"
versionFiles=(flake.lock "$claudePin" "$chatgptCask")
before="$(mktemp -d)"
trap 'rm -rf "$before"' EXIT
for file in "${versionFiles[@]}"; do
  mkdir -p "$before/$(dirname "$file")"
  cp "$file" "$before/$file"
done

if [[ "$fullUpdate" == true ]]; then
  echo "==> Updating every input"
  nix flake update
elif (( ${#inputs[@]} > 0 )); then
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
refreshClaudePin="$fullUpdate"
for input in "${inputs[@]}"; do
  [[ "$input" == "llm-agents" ]] && refreshClaudePin=true
done

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

# ── ChatGPT / Codex: re-vendor the pinned cask from upstream ────────────────
# ChatGPT.app (which bundles the codex CLI) is served from the in-repo pinned
# tap, not from the homebrew-cask input — see the declaration in
# modules/darwin/homebrew.nix for why. A pin only the lock cannot move needs
# its own mover, or it goes stale silently: it sat at 26.825 for a week after
# 2026-09-01 with nothing reporting the gap. This is that mover.
#
# The bytes come from upstream homebrew-cask's CURRENT chatgpt.rb, vendored
# verbatim under a provenance header. Upstream is not a repackager here: its
# `url` is OpenAI's own versioned zip on persistent.oaistatic.com, and its
# bump bot follows the same Sparkle appcast the app's updater reads, within
# hours (measured 2026-09-05: appcast published 26.901.41600 at 02:13Z,
# homebrew-cask committed it at 03:40Z). Vendoring rather than downloading
# the zips ourselves keeps both architectures' sha256 real without pulling
# two multi-hundred-MB archives per run. The appcast is still consulted, so
# a run always says whether upstream has caught up with OpenAI or not.
#
# Following upstream also follows it DOWN, exactly like the claude-code pin:
# if a release is pulled, the next refresh pulls it here. A version that is
# broken IN USE is not something upstream knows about — hold it by reverting
# the vendored file, as 2026-09-01 did, and this refresh will re-adopt the
# next upstream move, so re-run it deliberately.
if [[ "$refreshChatgpt" == true ]]; then
  upstreamCaskPath="Casks/c/chatgpt.rb"
  chatgptBefore="$(caskVersion "$chatgptCask")"
  # The commit that last touched the cask, so the vendored header can name
  # the exact revision it came from; the raw fetch is then pinned to that sha.
  upstreamCommit=""
  if command -v gh >/dev/null 2>&1; then
    upstreamCommit="$(gh api "repos/Homebrew/homebrew-cask/commits?path=${upstreamCaskPath}&per_page=1" \
      --jq '.[0].sha' 2>/dev/null || true)"
  fi
  if [[ -z "$upstreamCommit" ]]; then
    upstreamCommit="$(curl -fsSL --max-time 15 \
      "https://api.github.com/repos/Homebrew/homebrew-cask/commits?path=${upstreamCaskPath}&per_page=1" 2>/dev/null \
      | jq -r '.[0].sha // empty' 2>/dev/null || true)"
  fi
  if [[ "$upstreamCommit" =~ ^[0-9a-f]{40}$ ]] \
    && upstreamCaskBody="$(curl -fsSL --max-time 15 \
      "https://raw.githubusercontent.com/Homebrew/homebrew-cask/${upstreamCommit}/${upstreamCaskPath}")" \
    && upstreamVersion="$(caskVersion <(printf '%s\n' "$upstreamCaskBody"))" \
    && [[ "$upstreamVersion" =~ ^[0-9]+(\.[0-9]+)+$ ]] \
    && grep -q 'sha256 arm: *"[0-9a-f]\{64\}"' <<<"$upstreamCaskBody"; then
    if [[ "$upstreamVersion" != "$chatgptBefore" ]]; then
      {
        printf '%s\n' \
          "# Vendored VERBATIM (below this header) from homebrew-cask revision" \
          "# ${upstreamCommit} by scripts/update.sh chatgpt on $(date -u +%Y-%m-%d)." \
          "# Why ChatGPT is pinned here instead of taken from the homebrew-cask input," \
          "# and how to move or unpin it, is documented at the cask declaration in" \
          "# modules/darwin/homebrew.nix; the matching Sparkle self-update kill switch" \
          "# is modules/home/chatgpt.nix."
        printf '%s\n' "$upstreamCaskBody"
      } > "$chatgptCask"
    fi
    # OpenAI's own feed, the newest entry. Not adopted from here — the appcast
    # carries no sha256 — but reported, so "current" always means current
    # against OpenAI rather than merely against upstream homebrew-cask.
    appcastVersion="$(curl -fsSL --max-time 15 \
      "https://persistent.oaistatic.com/codex-app-prod/appcast.xml" 2>/dev/null \
      | sed -n 's/.*<sparkle:shortVersionString>\([^<]*\)<.*/\1/p' | head -n 1 || true)"
    if [[ -z "$appcastVersion" ]]; then
      echo "    chatgpt: vendored ${upstreamVersion} — could not read OpenAI's appcast to compare" >&2
    elif [[ "$appcastVersion" != "$upstreamVersion" ]]; then
      echo "    chatgpt: vendored ${upstreamVersion}; OpenAI's appcast has ${appcastVersion} and upstream homebrew-cask has not bumped yet — re-run later to adopt it"
    fi
  else
    echo "    warning: could not read upstream homebrew-cask's chatgpt cask; chatgpt stays at ${chatgptBefore}" >&2
  fi
fi

unchanged=true
for file in "${versionFiles[@]}"; do
  /usr/bin/cmp -s "$before/$file" "$file" || unchanged=false
done
if [[ "$unchanged" == true ]]; then
  echo "==> Already current; nothing moved"
  exit 0
fi

# One line per moved pin, old -> new, given the old CONTENTS of the two pin
# files (a snapshot here, HEAD's copy for the landing step) and comparing the
# version each declares against the working tree's.
describePinMoves() {
  local oldClaude="$1" oldChatgpt="$2" was now
  was="$(jq -r .version <<<"$oldClaude")"
  now="$(jq -r .version "$claudePin")"
  [[ "$was" != "$now" ]] && echo "    claude-code: ${was} -> ${now}"
  was="$(caskVersion <(printf '%s\n' "$oldChatgpt"))"
  now="$(caskVersion "$chatgptCask")"
  [[ "$was" != "$now" ]] && echo "    chatgpt: ${was} -> ${now}"
  return 0
}

echo
echo "==> What moved"
if command -v jq >/dev/null 2>&1; then
  describeLockMoves "$before/flake.lock"
  describePinMoves "$(cat "$before/$claudePin")" "$(cat "$before/$chatgptCask")"
else
  git --no-pager diff --stat -- "${versionFiles[@]}" || true
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
  echo "    Review the diff of ${versionFiles[*]}, then run ./scripts/rebuild.sh"
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

if git diff --quiet HEAD -- "${versionFiles[@]}"; then
  echo "    ${versionFiles[*]} already match HEAD; nothing to land"
  exit 0
fi

# Refuse to automate a commit while unrelated tracked changes sit in the tree:
# branch-switching would drag them along, and an automated commit must never
# sweep in work it does not own. Untracked files are fine — committing only
# the version files cannot pick them up.
excludes=()
for file in "${versionFiles[@]}"; do
  excludes+=(":(exclude)$file")
done
if ! git diff --quiet HEAD -- . "${excludes[@]}"; then
  echo "error: tracked changes besides ${versionFiles[*]} are in the tree." >&2
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

# What moved, old -> new per line, for the commit message and PR body — the
# same listing the terminal summary printed, but computed against HEAD rather
# than the in-run snapshot so the recorded diff is exactly what this commit
# lands. Best-effort: jq's absence already only costs the staleness report
# above, and it only costs the detailed listing here.
moved="flake inputs and pins (jq unavailable for the detailed listing)"
if command -v jq >/dev/null 2>&1; then
  headLock="$(mktemp)"
  git show HEAD:flake.lock > "$headLock"
  moved="$(
    describePinMoves "$(git show "HEAD:$claudePin")" "$(git show "HEAD:$chatgptCask")"
    describeLockMoves "$headLock" || echo "    (listing failed)"
  )"
  rm -f "$headLock"
fi

# The commit title names the lock only when the lock moved; a pin-only run
# (`update.sh chatgpt`) must not be recorded as a flake input update.
title="chore(flake): update inputs"
if git diff --quiet HEAD -- flake.lock; then
  title="chore(pins): update pinned versions"
fi

branch="chore/flake-lock-$(date +%Y%m%d-%H%M%S)"
git switch -c "$branch"
git add "${versionFiles[@]}"
git commit -m "$title" -m "Moved:
${moved}

Landed by scripts/update.sh after nix flake check, a full system build,
and activation on the machine that ran the update."
git push -u origin "$branch"
gh pr create \
  --title "$title" \
  --body "Moved:

${moved}

Automated by \`scripts/update.sh\`: the versions were moved, \`nix flake check\` passed, the system built, and the result was activated before this commit was created."
# --delete-branch also checks the default branch out afterwards and pulls it,
# so a run started from main ends on an up-to-date main with a clean tree.
gh pr merge --squash --delete-branch

if [[ "$startBranch" != "$(git branch --show-current)" ]] \
  && git show-ref --quiet "refs/heads/$startBranch"; then
  git switch "$startBranch"
fi

echo
echo "==> Landed: $(git log --oneline -1 origin/main 2>/dev/null || true)"
