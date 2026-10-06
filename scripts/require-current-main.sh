#!/usr/bin/env bash
#
# Refuse to activate a checkout that is behind GitHub's main.
#
# Activation makes the machine match the checkout, so an older checkout
# silently undoes everything merged since. On 2026-10-06 a rebuild from a
# worktree cut before #134 removed the Herdr Server.app launcher agent,
# which stopped the Herdr server and every pane running under it; an
# earlier one from a branch cut before #136 reinstalled a broken
# codex-orchestrator. A branch is fine as long as it contains origin/main.
#
# Usage: require-current-main.sh <repository>

set -euo pipefail

repository="$1"

if ! git -C "$repository" rev-parse --verify --quiet origin/main >/dev/null; then
  echo "warning: no origin/main in $repository; cannot check that it is current" >&2
  exit 0
fi

# Fetch so "current" means GitHub now, not the last fetch. Offline, fall back
# to the last fetched origin/main rather than blocking activation outright.
if ! git -C "$repository" fetch --quiet origin main 2>/dev/null; then
  echo "warning: could not fetch origin/main; checking against the last fetched copy" >&2
fi

if ! git -C "$repository" merge-base --is-ancestor origin/main HEAD; then
  behind=$(git -C "$repository" rev-list --count HEAD..origin/main)
  echo "error: this checkout ($(git -C "$repository" rev-parse --short HEAD)) is $behind commit(s) behind origin/main." >&2
  echo "Activating it would undo what was merged since. Rebase onto origin/main, or switch to main and pull, then rebuild." >&2
  exit 1
fi
