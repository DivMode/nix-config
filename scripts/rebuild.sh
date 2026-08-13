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
exec /usr/bin/sudo -A env NIX_CONFIG_LOCAL="$NIX_CONFIG_LOCAL" \
  /run/current-system/sw/bin/darwin-rebuild switch --impure \
  --flake "path:${repository}#${host}"
