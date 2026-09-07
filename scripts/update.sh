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
#   ./scripts/update.sh stillpane             # just the stillpane release
#   ./scripts/update.sh --dry-run             # update the lock, do not activate
#
# Two versions are pinned by files of this repository's own rather than by the
# lock, and this script refreshes those too, on a full run or by name: the
# claude-code pin, from Anthropic's release bucket (`llm-agents`), and the
# stillpane release, which is a vendored cask AND a flake input tag moved
# together from the project's latest GitHub release (`stillpane`).
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
refreshStillpane=false
inputs=()
for argument in "$@"; do
  case "$argument" in
    --dry-run) dryRun=true ;;
    # Not a plain flake input: the stillpane release is a vendored cask plus
    # the tag on the stillpane-src input, refreshed together below. Kept out
    # of `inputs` so `nix flake update` never sees a name it cannot move.
    stillpane|stillpane-src) refreshStillpane=true ;;
    -*)
      echo "error: unknown option $argument" >&2
      exit 1
      ;;
    *) inputs+=("$argument") ;;
  esac
done

# No arguments at all means everything: every lock input AND every pin. An
# explicit list moves exactly what it names.
fullUpdate=false
if (( ${#inputs[@]} == 0 )) && [[ "$refreshStillpane" == false ]]; then
  fullUpdate=true
  refreshStillpane=true
fi

# The version a vendored cask pins: the first `version "…"` line of the cask
# file, the same rule modules/darwin/homebrew.nix applies at evaluation time.
caskVersion() {
  sed -n 's/^ *version "\([^"]*\)".*/\1/p' "$1" | head -n 1
}

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
# stillpane-src is a tag pin too, but this script moves it (see the stillpane
# section below), so it is reported there and left out of this list.
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
             and .key != "stillpane-src"
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
stillpaneCask="taps/homebrew-pinned/Casks/stillpane.rb"
versionFiles=(flake.lock "$claudePin" "$stillpaneCask")

# The stillpane refresh also rewrites the tag in flake.nix, so on a run that
# refreshes it flake.nix is one of the files this script owns and lands. It
# is added ONLY on those runs, and only when flake.nix is clean: the landing
# step commits every file in versionFiles, and an unrelated edit sitting in
# flake.nix must never be swept into an automated version bump.
if [[ "$refreshStillpane" == true ]]; then
  if ! git diff --quiet HEAD -- flake.nix; then
    echo "error: flake.nix has uncommitted changes; not moving the stillpane tag over them." >&2
    echo "Commit or stash them, or run without 'stillpane' / with explicit inputs." >&2
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


# ── stillpane: cask and plugin tag, moved together from the latest release ──
# stillpane is two pins that must agree: the vendored cask in the in-repo
# tap (no upstream cask exists — see the cask header) and the tag on the
# stillpane-src flake input, which feeds the Claude Code plugin the same
# release ships. The app's own Check Setup compares the two, so they move as
# one, from one source: the project's latest GitHub release.
#
# The dmg is downloaded once, hashed for the cask, and — before anything is
# rewritten — mounted and checked against the same codesign requirement the
# project's own installer skill enforces: stillpane's bundle identifier under
# its Developer Team ID. A release that fails that check is not adopted, and
# the run says so; a hash alone would faithfully pin whatever was uploaded.
#
# Nothing here reaches the Mac's installed copy. The cask moves at the next
# activation; the plugin is reinstalled by modules/home/stillpane.nix when
# the store copy changes.
stillpaneRepo="yayamaz/stillpane"
stillpaneRequirement='=anchor apple generic and identifier "app.stillpane.Stillpane" and certificate leaf[subject.OU] = "7NV7GLDW87"'
if [[ "$refreshStillpane" == true ]]; then
  stillpaneBefore="$(caskVersion "$stillpaneCask")"
  stillpaneTag=""
  if command -v gh >/dev/null 2>&1; then
    stillpaneTag="$(gh api "repos/${stillpaneRepo}/releases/latest" --jq '.tag_name' 2>/dev/null || true)"
  fi
  if [[ -z "$stillpaneTag" ]]; then
    stillpaneTag="$(curl -fsSL --max-time 15 "https://api.github.com/repos/${stillpaneRepo}/releases/latest" 2>/dev/null \
      | jq -r '.tag_name // empty' 2>/dev/null || true)"
  fi
  if [[ ! "$stillpaneTag" =~ ^v[0-9]+(\.[0-9]+)+$ ]]; then
    echo "    warning: could not determine the latest stillpane release; stillpane stays at ${stillpaneBefore}" >&2
  elif [[ "${stillpaneTag#v}" == "$stillpaneBefore" ]]; then
    echo "==> stillpane: ${stillpaneBefore} (current)"
  else
    stillpaneVersion="${stillpaneTag#v}"
    stillpaneTmp="$(mktemp -d -t stillpane)"
    stillpaneDmg="$stillpaneTmp/stillpane.dmg"
    stillpaneMount="$stillpaneTmp/mount"
    mkdir -p "$stillpaneMount"
    stillpaneOk=false
    if curl -fsSL --max-time 120 -o "$stillpaneDmg" \
        "https://github.com/${stillpaneRepo}/releases/download/${stillpaneTag}/stillpane-${stillpaneVersion}.dmg" \
      && /usr/bin/hdiutil attach -nobrowse -readonly -quiet -mountpoint "$stillpaneMount" "$stillpaneDmg"; then
      if /usr/bin/codesign --verify --strict --deep -R "$stillpaneRequirement" "$stillpaneMount/stillpane.app" 2>/dev/null \
        && [[ "$(/usr/bin/defaults read "$stillpaneMount/stillpane.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)" == "$stillpaneVersion" ]]; then
        stillpaneOk=true
      fi
      /usr/bin/hdiutil detach -quiet "$stillpaneMount" || true
    fi
    if [[ "$stillpaneOk" == true ]]; then
      stillpaneSha="$(/usr/bin/shasum -a 256 "$stillpaneDmg" | /usr/bin/awk '{ print $1 }')"
      sed -i '' \
        -e "s/^  version \".*\"/  version \"${stillpaneVersion}\"/" \
        -e "s/^  sha256 \".*\"/  sha256 \"${stillpaneSha}\"/" \
        "$stillpaneCask"
      sed -i '' \
        -e "s|github:${stillpaneRepo}/v[0-9][0-9.]*\"|github:${stillpaneRepo}/${stillpaneTag}\"|" \
        flake.nix
      nix flake update stillpane-src
      echo "==> stillpane: ${stillpaneBefore} -> ${stillpaneVersion} (cask and plugin tag)"
    else
      echo "    warning: stillpane ${stillpaneTag} did not verify as a build of app.stillpane.Stillpane signed by team 7NV7GLDW87 at that version; stillpane stays at ${stillpaneBefore}" >&2
    fi
    rm -rf "$stillpaneTmp"
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
  local oldClaude="$1" oldStillpane="$2" was now
  was="$(jq -r .version <<<"$oldClaude")"
  now="$(jq -r .version "$claudePin")"
  [[ "$was" != "$now" ]] && echo "    claude-code: ${was} -> ${now}"
  was="$(caskVersion <(printf '%s\n' "$oldStillpane"))"
  now="$(caskVersion "$stillpaneCask")"
  [[ "$was" != "$now" ]] && echo "    stillpane: ${was} -> ${now}"
  return 0
}

echo
echo "==> What moved"
if command -v jq >/dev/null 2>&1; then
  describeLockMoves "$before/flake.lock"
  describePinMoves "$(cat "$before/$claudePin")" "$(cat "$before/$stillpaneCask")"
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
    describePinMoves "$(git show "HEAD:$claudePin")" "$(git show "HEAD:$stillpaneCask")"
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
