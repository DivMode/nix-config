#!/usr/bin/env bash
#
# Point this clone's Git hooks at scripts/hooks.
#
# Hooks are per-clone: `.git/hooks` is not tracked and nothing in a fresh clone
# runs the guard until this has been executed once. It is therefore called from
# scripts/rebuild.sh and scripts/setup-mac.sh rather than left to memory — a
# guard that has to be installed by hand is a guard that is absent on the one
# machine where it mattered.
#
# Idempotent: re-running it is a no-op once the value is already set.

set -euo pipefail

repository="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository"

git rev-parse --git-dir >/dev/null 2>&1 || exit 0

desired="scripts/hooks"
current=$(git config --local --get core.hooksPath || true)

if [[ "$current" != "$desired" ]]; then
  git config --local core.hooksPath "$desired"
  echo "==> Git hooks now run from $desired"
fi

chmod +x "$repository/$desired"/* 2>/dev/null || true
