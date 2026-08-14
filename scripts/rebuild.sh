#!/usr/bin/env bash
#
# Activate this host's configuration, prompting for the password in a GUI
# dialog rather than on a terminal.
#
# This is the same command documented in docs/operations/rebuild.md, wrapped so
# it can be started from a shell with no controlling terminal. Everything
# before activation is a pure build: nothing touches the Mac until the final
# `darwin-rebuild switch` line.

set -euo pipefail

repository="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository"

if [[ ! -f local.nix ]]; then
  echo "error: $repository/local.nix is missing; see docs/setup/new-mac.md" >&2
  exit 1
fi

export NIX_CONFIG_LOCAL="$repository/local.nix"
export SUDO_ASKPASS="$repository/scripts/sudo-askpass.sh"

host="${1:-example-mac}"

echo "==> Building $host"
nix build --no-link --impure ".#darwinConfigurations.${host}.system"

echo "==> Activating $host (password dialog will appear)"
# --preserve-env, NOT an `env` wrapper: sudoers matches the literal command,
# and the NOPASSWD rule names darwin-rebuild — wrapping in `env` makes sudo
# see `env` and prompt despite the rule (measured 2026-08-14).
/usr/bin/sudo -A --preserve-env=NIX_CONFIG_LOCAL \
  /run/current-system/sw/bin/darwin-rebuild switch --impure \
  --flake "path:${repository}#${host}"

# ── Keep the 1Password copy of local.nix current ────────────────────────────
# local.nix is git-ignored (public repository) but is this machine's whole
# deploy identity — the Connect host, 1Password item IDs, and AWS profile
# wiring. scripts/setup-mac.sh restores it on a wiped machine from a Document
# item titled "nix-config local.nix <LocalHostName>" (vault <vault>), so
# that item must track every local.nix edit. Best-effort: runs only after a
# SUCCESSFUL activation (set -e above), and a locked or unauthenticated
# 1Password only warns.
host_name=$(/usr/sbin/scutil --get LocalHostName 2>/dev/null || true)
op_bin=$(command -v op || true)
if [[ -n "$host_name" && -n "$op_bin" ]]; then
  doc_title="nix-config local.nix $host_name"
  if stored=$("$op_bin" document get "$doc_title" --vault <vault> 2>/dev/null); then
    if [[ "$stored" != "$(cat local.nix)" ]]; then
      if "$op_bin" document edit "$doc_title" local.nix --vault <vault> >/dev/null 2>&1; then
        echo "==> Synced local.nix to 1Password ($doc_title)"
      else
        echo "warning: could not sync local.nix to 1Password — the stored copy is stale" >&2
      fi
    fi
  elif "$op_bin" document create local.nix --title "$doc_title" --vault <vault> --file-name local.nix >/dev/null 2>&1; then
    echo "==> Stored local.nix in 1Password ($doc_title)"
  else
    echo "warning: could not store local.nix in 1Password" >&2
  fi
fi
