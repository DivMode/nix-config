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

# Every activation re-asserts the private-name guard, so a fresh clone is
# protected from its first rebuild rather than from whenever someone remembers.
"$repository/scripts/install-hooks.sh"

host="${1:-example-mac}"

echo "==> Building $host"
nix build --no-link --impure ".#darwinConfigurations.${host}.system"

# ── 1Password must survive its own cask upgrade ─────────────────────────────
# Homebrew's 1password cask declares `quit: "com.1password.1password"`, so an
# activation that upgrades it quits the application and never starts it again.
# That is not cosmetic. ../modules/home/default.nix signs every commit with
# /Applications/1Password.app/Contents/MacOS/op-ssh-sign, which talks to the
# desktop app's SSH agent, so a dead 1Password means no commits at all.
#
# Measured 2026-08-27: the 11:41:41 cask upgrade quit it, nothing restarted it,
# and the next commit failed with "1Password: Could not connect to socket. Is
# the agent running?".
#
# The state is recorded BEFORE activation and acted on after, so this only ever
# restores what activation destroyed. An application the user had already quit
# themselves stays quit.
onePasswordWasRunning=false
if /usr/bin/pgrep -x 1Password >/dev/null 2>&1; then
  onePasswordWasRunning=true
fi

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

if [[ "$onePasswordWasRunning" == true ]] && ! /usr/bin/pgrep -x 1Password >/dev/null 2>&1; then
  echo "==> 1Password was quit by its cask upgrade; reopening it"
  /usr/bin/open -a 1Password

  # Confirm it actually came back rather than reporting success on the `open`
  # call alone. The agent socket is NOT the check: it is a filesystem entry
  # that outlives the process, and it was present on disk while 1Password was
  # dead on 2026-08-27 — a check that cannot fail is not a check. Unlocking is
  # deliberately not waited on; that is the user's to do, and a running agent
  # is what this script is responsible for.
  for _ in $(seq 1 20); do
    /usr/bin/pgrep -x 1Password >/dev/null 2>&1 && break
    sleep 0.5
  done

  if /usr/bin/pgrep -x 1Password >/dev/null 2>&1; then
    echo "==> 1Password is running again"
  else
    echo "warning: 1Password did not come back; commit signing will fail until it does" >&2
  fi
fi

# ── Keep the 1Password copy of local.nix current ────────────────────────────
# local.nix is git-ignored (public repository) but is this machine's whole
# deploy identity — the Connect host, 1Password item IDs, and AWS profile
# wiring. scripts/setup-mac.sh restores it on a wiped machine from a Document
# item titled "nix-config local.nix <LocalHostName>", so that item must track
# every local.nix edit. Best-effort: runs only after a SUCCESSFUL activation
# (set -e above), and a locked or unauthenticated 1Password only warns.
#
# The vault comes FROM local.nix. It was hard-coded here until 2026-08-14, when
# an audit found the vault name — a private name — in four lines of this script
# and two of the wizard, in a public repository.
host_name=$(/usr/sbin/scutil --get LocalHostName 2>/dev/null || true)
op_bin=$(command -v op || true)
vault=$(LOCAL_PATH="$repository/local.nix" nix eval --impure --raw --expr \
  '(import (builtins.toPath (builtins.getEnv "LOCAL_PATH"))).onePassword.vault or ""' 2>/dev/null || true)
if [[ -z "$vault" ]]; then
  echo "warning: local.nix has no onePassword.vault — skipping the 1Password sync" >&2
elif [[ -n "$host_name" && -n "$op_bin" ]]; then
  doc_title="nix-config local.nix $host_name"
  if stored=$("$op_bin" document get "$doc_title" --vault "$vault" 2>/dev/null); then
    if [[ "$stored" != "$(cat local.nix)" ]]; then
      if "$op_bin" document edit "$doc_title" local.nix --vault "$vault" >/dev/null 2>&1; then
        echo "==> Synced local.nix to 1Password ($doc_title)"
      else
        echo "warning: could not sync local.nix to 1Password — the stored copy is stale" >&2
      fi
    fi
  elif "$op_bin" document create local.nix --title "$doc_title" --vault "$vault" --file-name local.nix >/dev/null 2>&1; then
    echo "==> Stored local.nix in 1Password ($doc_title)"
  else
    echo "warning: could not store local.nix in 1Password" >&2
  fi
fi
