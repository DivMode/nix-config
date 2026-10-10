#!/usr/bin/env bash
#
# Activate this host's configuration, prompting for the password in a GUI
# dialog rather than on a terminal.
#
# This is the same command documented in docs/operations/rebuild.md, wrapped so
# it can be started from a shell with no controlling terminal. It never calls
# the 1Password CLI or the desktop application: the local.nix backup is saved
# through Connect. First-time setup belongs to setup-mac.sh.

set -euo pipefail

repository="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository"

# local.nix is ignored, so a linked worktree has none of its own: use the main
# checkout's, the same machine's same file (as check-private-names.sh does).
local_file="$repository/local.nix"
if [[ ! -f "$local_file" ]]; then
  common_dir="$(git -C "$repository" rev-parse --path-format=absolute --git-common-dir)"
  local_file="$(dirname "$common_dir")/local.nix"
fi
if [[ ! -f "$local_file" ]]; then
  echo "error: $repository/local.nix is missing; see docs/setup/new-mac.md" >&2
  exit 1
fi

export NIX_CONFIG_LOCAL="$local_file"
export SUDO_ASKPASS="$repository/scripts/sudo-askpass.sh"

if [[ -n "${NIX_CONFIG_SETUP_BOOTSTRAP:-}" ]]; then
  echo "error: install-only bootstrap is reserved for the interactive setup wizard, not routine rebuilding." >&2
  exit 1
fi

# Every activation re-asserts the private-name guard, so a fresh clone is
# protected from its first rebuild rather than from whenever someone remembers.
"$repository/scripts/install-hooks.sh"

host="${1:-example-mac}"

# Never activate a checkout older than GitHub's main; see the script.
"$repository/scripts/require-current-main.sh" "$repository"

echo "==> Building $host"
nix build --no-link --impure ".#darwinConfigurations.${host}.system"


echo "==> Activating $host (password dialog will appear)"
# --preserve-env, NOT an `env` wrapper: sudoers matches the literal command,
# and the NOPASSWD rule names darwin-rebuild — wrapping in `env` makes sudo
# see `env` and prompt despite the rule (measured 2026-08-14).
#
# SUDO_ASKPASS is preserved alongside NIX_CONFIG_LOCAL. Necessary, but NOT
# sufficient on its own, and the distinction is worth writing down.
#
# Homebrew starts a SECOND, nested sudo for any cask shipping an installer
# script rather than an app bundle. Per sudo(8), SUDO_ASKPASS is used
# automatically "if no terminal is available" — exactly that case — but only if
# the variable is still in the environment by then, and it is not. nix-darwin
# performs a further hop of its own during activation:
#
#   sudo --preserve-env=PATH --user=<user> --set-home ... brew bundle
#
# --preserve-env is a whitelist naming only PATH, so SUDO_ASKPASS is dropped
# there regardless of what this script exports. Passing it from here fixes the
# first hop and cannot fix the second.
#
# Measured 2026-08-21 installing logi-options+: "sudo: a terminal is required
# to read the password", the cask failed, the bundle reported that failure, and
# darwin-rebuild still exited 0 — so activation looked successful with the
# application simply absent. A cask with a sudo installer therefore cannot be
# installed by an unattended activation today. It needs either a terminal, or
# an askpass path declared in sudo.conf(5), which no environment hop can strip.
/usr/bin/sudo -A --preserve-env=NIX_CONFIG_LOCAL,SUDO_ASKPASS \
  /run/current-system/sw/bin/darwin-rebuild switch --impure \
  --flake "path:${repository}#${host}"

# ── Keep the 1Password copy of local.nix current, through Connect ───────────
# The host's local.nix (Connect host, item IDs, AWS profiles: everything a new
# Mac needs) is stored as the Secure Note "nix-config local.nix"
# in the vault named by local.nix's onePassword.vault. It is created or updated
# after every successful activation and read back to verify the exact text.
# Connect cannot write Document items, hence a Secure Note. A failure is loud:
# activation has already succeeded, but the backup is not current.
vault=$(nix eval --impure --raw --expr \
  '(import (builtins.toPath (builtins.getEnv "NIX_CONFIG_LOCAL"))).onePassword.vault or ""')
if [[ -z "$vault" ]]; then
  echo "error: local.nix sets no onePassword.vault, so the local.nix backup has nowhere to go." >&2
  exit 1
fi
note_bin="/etc/profiles/per-user/$(id -un)/bin/nix-config-connect-note"
if ! outcome=$("$note_bin" save "$vault" "nix-config local.nix" "$local_file"); then
  echo "ERROR: activation succeeded, but the local.nix backup in 1Password could not be saved through Connect (see above)." >&2
  exit 1
fi
echo "==> local.nix backup in 1Password: $outcome and verified"

# Warn, never fail, about a declared kubeconfig this Mac lacks; setup-mac.sh restores them.
"$repository/scripts/kubeconfigs.sh" --check || true

# Warn, never fail, when the 1Password copy of the Connect token is not the one
# in use: a new Mac is set up from that copy, so a replaced token that was never
# stored leaves the next setup with a token that may no longer work.
if ! "/etc/profiles/per-user/$(id -un)/bin/nix-config-connect-store-token" ids >/dev/null; then
  echo "warning: the stored Connect token copy is not the token in use; run: nix-config-connect-store-token store" >&2
fi
