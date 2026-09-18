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
# Typed as `nixup` — modules/home/default.nix aliases it, and arguments pass
# through — so nobody types this path:
#
#   nixup                    # every input and every pin
#   nixup claude             # Claude Code: the llm-agents input and the pin
#   nixup codex              # ChatGPT/Codex: the cask definition, plus where the app stands
#   nixup gcx                # gcx: the release tag in flake.nix and the Go vendor hash
#   nixup herdr              # Herdr: the llm-agents input that packages it
#   nixup homebrew-cask      # any flake input by its name in flake.nix
#   nixup --dry-run          # move the versions and build, do not activate
#
# An application name is accepted wherever it is clearer than the input that
# carries it; the table in the argument parser below maps each to what moves.
# A name that is neither an application nor a flake input is refused with the
# list of both, rather than handed to nix to fail on.
#
# Two things are pinned outside the lock, and this script moves those too, on
# a full run or by name: the claude-code pin, from Anthropic's release bucket
# (`claude`), and any input whose URL in flake.nix names a release TAG, which
# `nix flake update` alone never moves — the tag is rewritten to the latest
# GitHub release and the input re-locked (`gcx`, currently the only one).
# "Every input" means every input: nothing declared here waits for a hand edit.
#
# Most declared casks carry Homebrew's `auto_updates` flag and update themselves,
# so they are unaffected either way — ChatGPT.app, which carries the codex CLI,
# is one of those and keeps itself current through Sparkle. The ones that
# depend on this script are the casks with no self-updater — currently
# 1password-cli.

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
# Every direct flake input, from the lock rather than a hand-kept list, so a
# new input is accepted the moment it is locked.
knownInputs="$(jq -r '.nodes.root.inputs | keys[]' flake.lock 2>/dev/null || true)"
for argument in "$@"; do
  case "$argument" in
    --dry-run) dryRun=true ;;
    # ── Application names → what moves ──────────────────────────────────────
    # Claude Code: the llm-agents input carries the build recipe, and the
    # version pin is refreshed whenever that input is named (see below).
    claude|claude-code) inputs+=(llm-agents) ;;
    # Herdr is llm-agents' package too (modules/home/herdr), served prebuilt
    # from numtide's cache.
    herdr) inputs+=(llm-agents) ;;
    # ChatGPT.app, which bundles the codex CLI, updates itself through Sparkle
    # and nothing declarative can hold or move it (modules/darwin/homebrew.nix,
    # `chatgpt`). What this repository owns is the cask DEFINITION a fresh
    # machine installs from, which lives in the homebrew-cask input; the
    # report section below then says where the installed app stands and that
    # launching it is how it moves.
    codex|chatgpt) inputs+=(homebrew-cask) ;;
    # gcx is a release-tag pin; naming it moves the tag (see the tag section).
    gcx) inputs+=(gcx-src) ;;
    -*)
      echo "error: unknown option $argument" >&2
      exit 1
      ;;
    *)
      if ! grep -qx -- "$argument" <<<"$knownInputs"; then
        echo "error: '$argument' is neither an application name nor a flake input." >&2
        echo "applications: claude, codex, gcx, herdr" >&2
        echo "flake inputs: $(tr '\n' ' ' <<<"$knownInputs")" >&2
        exit 1
      fi
      inputs+=("$argument")
      ;;
  esac
done

# No arguments at all means everything: every lock input AND every pin. An
# explicit list moves exactly what it names.
fullUpdate=false
if (( ${#inputs[@]} == 0 )); then
  fullUpdate=true
fi

host="${HOST:-example-mac}"

# ── Tag-pinned inputs: found here, moved below ──────────────────────────────
# An input whose flake.nix URL names a release tag (gcx-src) is not moved by
# `nix flake update`: the lock can only re-resolve the tag it was given. Until
# 2026-09-17 adoption was a hand edit of flake.nix and this section only
# reported staleness — which in practice meant the pins sat behind while every
# other input advanced (herdr v0.9.0 against v0.9.1, gcx v1.2.0 against
# v1.3.0 on the day this changed). Now a full run, or a run naming the input,
# moves each direct tag pin to upstream's latest release: this section finds
# what is behind, and the step after `nix flake update` rewrites the tag and
# re-locks it. The move is still a reviewable diff — it is printed under "What
# moved" and lands as its own line in the PR — and still gated by the check,
# build and activation below.
#
# The gcx 1.0→1.1 output-shape change (2026-08-16), which silently inverted a
# health check's verdict, is why this prints every move loudly rather than
# folding it into the lock noise. Failures to reach GitHub are printed too: a
# check that cannot run must not read as "everything current".
#
# Transitive tag pins (brew-src, inside nix-homebrew) are reported only; they
# are their owner's to move.
tagMoves=()
wantsInput() {
  local wanted
  [[ "$fullUpdate" == true ]] && return 0
  for wanted in "${inputs[@]}"; do
    [[ "$wanted" == "$1" ]] && return 0
  done
  return 1
}
echo "==> Tag-pinned inputs"
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
    elif [[ "$via" == "direct" && ! "$latest" =~ ^v?[0-9]+(\.[0-9]+)+$ ]]; then
      echo "    ${name}: pinned ${ref}; upstream's latest release is tagged '${latest}', not a plain version — not moving to it" >&2
    elif [[ "$via" == "direct" ]] && wantsInput "$name"; then
      echo "    ${name}: pinned ${ref}, upstream has ${latest} — moving"
      tagMoves+=("${name}"$'\t'"${owner}"$'\t'"${repo}"$'\t'"${ref}"$'\t'"${latest}")
    elif [[ "$via" == "direct" ]]; then
      echo "    ${name}: pinned ${ref}, upstream has ${latest} — not named in this run; './scripts/update.sh ${name}' moves it"
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

# ── ChatGPT / Codex: where it is, reported, not moved ───────────────────────
# ChatGPT.app carries the codex CLI and is a plain auto_updates cask: Homebrew
# installs it once and Sparkle keeps it current from OpenAI's own appcast. It
# was held in an in-repo pinned tap from 2026-09-01 to 2026-09-05, with a
# Sparkle kill switch in user defaults, until measurement showed the app
# rewrites both SU* keys to true within ten seconds of every launch — no
# declarative hold exists, so the pin was removed rather than kept as
# decoration. What this script CAN do is say where things stand: the app's
# own version, what the lock's cask definition would install on a fresh
# machine, and what OpenAI has published. If the app is behind, launching it
# is the update; if the lock is behind, `./scripts/update.sh homebrew-cask`.
echo "==> ChatGPT / Codex (updates itself through Sparkle; reported, not moved here)"
chatgptApp="/Applications/ChatGPT.app"
if [[ -d "$chatgptApp" ]]; then
  appVersion="$(/usr/bin/defaults read "$chatgptApp/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo unknown)"
  codexVersion="$("$chatgptApp/Contents/Resources/codex" --version 2>/dev/null || echo unknown)"
  lockRev="$(jq -r '.nodes["homebrew-cask"].locked.rev // empty' flake.lock 2>/dev/null || true)"
  lockVersion="$(curl -fsSL --max-time 10 \
    "https://raw.githubusercontent.com/Homebrew/homebrew-cask/${lockRev:-HEAD}/Casks/c/chatgpt.rb" 2>/dev/null \
    | sed -n 's/^ *version "\([^"]*\)".*/\1/p' | head -n 1 || true)"
  appcastVersion="$(curl -fsSL --max-time 10 \
    "https://persistent.oaistatic.com/codex-app-prod/appcast.xml" 2>/dev/null \
    | sed -n 's/.*<sparkle:shortVersionString>\([^<]*\)<.*/\1/p' | head -n 1 || true)"
  echo "    installed app ${appVersion} (${codexVersion}); lock's cask ${lockVersion:-unknown}; OpenAI's appcast ${appcastVersion:-unknown}"
  if [[ -n "$appcastVersion" && "$appVersion" != "$appcastVersion" ]]; then
    echo "    app is behind OpenAI — launch ChatGPT (or Check for Updates in it) to move it"
  fi
else
  echo "    ChatGPT.app not installed"
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

# Keep the pre-update state so the summary below reports what actually changed
# rather than what was requested. Every file this script may move is listed in
# versionFiles: the lock, and the pin this repository keeps itself.
claudePin="modules/home/claude-code-pin.json"
gcxPin="modules/home/gcx-pin.json"
versionFiles=(flake.lock "$claudePin" "$gcxPin")

# Moving a tag rewrites flake.nix, so on a run that moves one flake.nix is a
# file this script owns and lands. It is added ONLY on those runs, and only
# when flake.nix is clean: the landing step commits every file in
# versionFiles, and an unrelated edit sitting in flake.nix must never be swept
# into an automated version bump.
if (( ${#tagMoves[@]} > 0 )); then
  if ! git diff --quiet HEAD -- flake.nix; then
    echo "error: flake.nix has uncommitted changes; not moving release tags over them." >&2
    echo "Commit or stash them, then run again." >&2
    exit 1
  fi
  versionFiles+=(flake.nix)
fi
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

# ── Tag-pinned inputs: rewrite the tag, re-lock ─────────────────────────────
# The URL in flake.nix is the single place a tag is written; versions derived
# from it (gcx's, in modules/home/development.nix) are read back from the lock.
# The sed is anchored on the exact `github:owner/repo/oldtag"` string found in
# the lock, and verified to have changed the file, so a URL written any other
# way fails loudly instead of re-locking the old tag and calling it moved.
tagMoveLines=()
for move in "${tagMoves[@]}"; do
  IFS=$'\t' read -r name owner repo ref latest <<<"$move"
  sed -i '' -e "s|github:${owner}/${repo}/${ref}\"|github:${owner}/${repo}/${latest}\"|" flake.nix
  if ! grep -q "github:${owner}/${repo}/${latest}\"" flake.nix; then
    echo "error: could not find 'github:${owner}/${repo}/${ref}' in flake.nix to move ${name} to ${latest}" >&2
    exit 1
  fi
  nix flake update "$name"
  tagMoveLines+=("    ${name}: ${ref} -> ${latest}")
done

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


unchanged=true
for file in "${versionFiles[@]}"; do
  /usr/bin/cmp -s "$before/$file" "$file" || unchanged=false
done
if [[ "$unchanged" == true ]]; then
  echo "==> Already current; nothing moved"
  exit 0
fi

# One line per moved pin, old -> new, given the old CONTENTS of each pin file
# (a snapshot here, HEAD's copy for the landing step).
describePinMoves() {
  local oldClaude="$1" was now
  was="$(jq -r .version <<<"$oldClaude")"
  now="$(jq -r .version "$claudePin")"
  [[ "$was" != "$now" ]] && echo "    claude-code: ${was} -> ${now}"
  return 0
}

echo
echo "==> What moved"
if command -v jq >/dev/null 2>&1; then
  describeLockMoves "$before/flake.lock"
  describePinMoves "$(cat "$before/$claudePin")"
  (( ${#tagMoveLines[@]} > 0 )) && printf '%s\n' "${tagMoveLines[@]}"
else
  git --no-pager diff --stat -- "${versionFiles[@]}" || true
fi

# Everything from here to the final activation is a pure build: a failure leaves
# the Mac untouched and the lock change still sitting in the working tree for
# inspection.
echo
echo "==> Checking"
nix flake check --impure

# gcx is a Go program, and a release that changed its Go dependencies changes
# the hash of its vendored modules — a fixed-output derivation whose hash has
# to be declared (modules/home/gcx-pin.json) before it can be known. Nix
# reports the real one in the failure, so when the gcx tag moved and the build
# stops on exactly that mismatch, the reported hash is written to the pin and
# the build runs once more. Any other failure, or a second one, is fatal as
# before. The hash is of content fetched from the Go module proxy against
# go.sum, which is the same trust the hand-copied hash always had.
buildSystem() {
  nix build --no-link --impure ".#darwinConfigurations.${host}.system" 2>&1 | tee "$before/build.log"
  return "${PIPESTATUS[0]}"
}

echo "==> Building $host"
if ! buildSystem; then
  gcxVendorHash=""
  if printf '%s\n' "${tagMoveLines[@]}" | grep -q '^    gcx-src:'; then
    gcxVendorHash="$(/usr/bin/awk '
      /hash mismatch in fixed-output derivation .*-gcx-[^ ]*-go-modules\.drv/ { found = 1 }
      found && $1 == "got:" { print $2; exit }' "$before/build.log")"
  fi
  if [[ ! "$gcxVendorHash" =~ ^sha256-[A-Za-z0-9+/]{43}=$ ]]; then
    exit 1
  fi
  echo "==> gcx's Go dependencies changed; vendor hash -> ${gcxVendorHash}"
  jq -n --arg vendorHash "$gcxVendorHash" '{ vendorHash: $vendorHash }' > "$gcxPin"
  buildSystem
fi

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
    describePinMoves "$(git show "HEAD:$claudePin")"
    (( ${#tagMoveLines[@]} > 0 )) && printf '%s\n' "${tagMoveLines[@]}"
    describeLockMoves "$headLock" || echo "    (listing failed)"
  )"
  rm -f "$headLock"
fi

# The commit title names the lock only when the lock moved; a pin-only run
# (`update.sh llm-agents` with an unchanged lock) must not be recorded as a
# flake input update.
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
