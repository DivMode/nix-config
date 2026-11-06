#!/usr/bin/env bash
#
# Point the Git hooks of nix-config and of every other public repository at
# nix-config's scripts/hooks.
#
# Hooks are per-clone: `.git/hooks` is not tracked and nothing in a fresh clone
# runs the guard until this has been executed once. It is therefore called from
# scripts/rebuild.sh and scripts/setup-mac.sh rather than left to memory — a
# guard that has to be installed by hand is a guard that is absent on the one
# machine where it mattered.
#
# The public repositories are the checkouts local.nix names as `nixconfig` and
# in `publicProjects`. nix-config keeps the relative `scripts/hooks`, so each of
# its linked worktrees runs its own branch's hooks: a branch that changes the
# guard is committed by the guard it changes. Every other public repository
# carries no hooks of its own, so its core.hooksPath is the absolute path of
# the canonical nix-config checkout's scripts/hooks. A public checkout that is
# not on disk is skipped.
#
# Idempotent: re-running it is a no-op once every value is already set.

set -euo pipefail

repository="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

git -C "$repository" rev-parse --git-dir >/dev/null 2>&1 || exit 0

git_common_dir="$(git -C "$repository" rev-parse --path-format=absolute --git-common-dir)"
canonical_repository="$(cd "$(dirname "$git_common_dir")" && pwd)"
desired="$canonical_repository/scripts/hooks"

chmod +x "$desired"/* 2>/dev/null || true

install_into() { # <checkout> <hooksPath>
  local current
  current=$(git -C "$1" config --local --get core.hooksPath || true)
  if [[ "$current" != "$2" ]]; then
    git -C "$1" config --local core.hooksPath "$2"
    echo "==> Git hooks for $1 now run from $2${current:+ (was $current)}"
  fi
}

install_into "$canonical_repository" scripts/hooks

# local.nix is ignored, so a linked worktree has none of its own.
local_file="${NIX_CONFIG_LOCAL:-$repository/local.nix}"
if [[ -z "${NIX_CONFIG_LOCAL:-}" && ! -f "$local_file" ]]; then
  local_file="$canonical_repository/local.nix"
fi
if [[ ! -f "$local_file" ]] || ! command -v nix >/dev/null 2>&1; then
  echo "==> Cannot read the public projects (no local.nix or no nix yet): only nix-config's hooks are installed; rerun this once both exist." >&2
  exit 0
fi

if ! checkouts=$(LOCAL_PATH="$local_file" nix eval --impure --raw --expr '
  let
    local = import (builtins.toPath (builtins.getEnv "LOCAL_PATH"));
    projects = local.projects or { };
    names = builtins.filter (name: projects ? ${name}) ([ "nixconfig" ] ++ (local.publicProjects or [ ]));
  in
  builtins.concatStringsSep "\n" (map (name: projects.${name}) names)
'); then
  echo "error: could not read the public projects from $local_file" >&2
  exit 1
fi

while IFS= read -r checkout; do
  [[ -n "$checkout" ]] || continue
  if [[ ! -e "$checkout/.git" ]]; then
    echo "==> Skipping $checkout: no checkout there on this machine" >&2
    continue
  fi
  [[ "$(cd "$checkout" && pwd -P)" == "$(cd "$canonical_repository" && pwd -P)" ]] && continue
  install_into "$checkout" "$desired"
done <<< "$checkouts"
