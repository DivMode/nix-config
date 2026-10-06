#!/bin/bash
# One command for a new Mac, run from Terminal after Setup Assistant:
#
#   curl -fsSL https://raw.githubusercontent.com/DivMode/nix-config/main/scripts/bootstrap.sh | bash
#
# Installs Apple's Command Line Tools and Nix without prompts, clones or
# updates this repository on the external Data drive, then runs the setup
# wizard. Safe to rerun: each step is skipped when already done. Nothing here
# uses 1Password; the wizard asks for the Connect URL and token once.
set -euo pipefail

REPO_URL="https://github.com/DivMode/nix-config.git"
TARGET="/Volumes/Data/Developer/nix-config"

fail() { printf '\nERROR: %s\n' "$1" >&2; exit 1; }
step() { printf '\n==> %s\n' "$1"; }

[[ "$(uname -s)" == Darwin ]] || fail "This bootstrap is for macOS."
[[ "$(id -u)" != 0 ]] || fail "Run this as your own user, not with sudo."
[[ -d /Volumes/Data ]] || fail "The external Data drive is not mounted at /Volumes/Data. Plug it in and rerun."

step "Apple Command Line Tools"
if xcode-select -p >/dev/null 2>&1; then
  echo "already installed"
else
  # The same unattended path Homebrew's installer uses: this marker makes
  # softwareupdate list the Command Line Tools package.
  marker=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  touch "$marker"
  label=$(softwareupdate -l 2>/dev/null \
    | sed -n 's/^[* ]*Label: \(Command Line Tools for Xcode.*\)$/\1/p' | sort -V | tail -n 1)
  [[ -n "$label" ]] || { rm -f "$marker"; fail "softwareupdate offers no Command Line Tools; run 'xcode-select --install' and rerun."; }
  sudo softwareupdate -i "$label" --verbose
  rm -f "$marker"
  xcode-select -p >/dev/null 2>&1 || fail "Command Line Tools did not install."
fi

step "Nix (official multi-user installer)"
if [[ -x /nix/var/nix/profiles/default/bin/nix ]]; then
  echo "already installed"
else
  installer=$(mktemp)
  curl --proto '=https' --tlsv1.2 -fsSL https://nixos.org/nix/install -o "$installer"
  sh "$installer" --daemon --yes --no-channel-add
  rm -f "$installer"
  [[ -x /nix/var/nix/profiles/default/bin/nix ]] || fail "Nix did not install."
fi
export PATH="/nix/var/nix/profiles/default/bin:$PATH"

step "nix-config on the Data drive"
if [[ -d "$TARGET/.git" ]]; then
  # Over HTTPS: the Connect-backed SSH transport is not configured yet.
  git -C "$TARGET" pull --ff-only "$REPO_URL" main
else
  mkdir -p "$(dirname "$TARGET")"
  git clone "$REPO_URL" "$TARGET"
fi

step "Setup wizard"
# stdin is this piped script; the wizard needs the terminal for its prompts.
exec "$TARGET/scripts/setup-mac.sh" </dev/tty
