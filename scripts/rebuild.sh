#!/usr/bin/env bash
#
# Activate this host's configuration, prompting for the password in a GUI
# dialog rather than on a terminal.
#
# This is the same command documented in docs/operations/rebuild.md, wrapped so
# it can be started from a shell with no controlling terminal. Credentials are
# supplied by the configured service account; this path never signs in through
# the desktop application. First-time credential setup belongs to setup-mac.sh.

set -euo pipefail

repository="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository"

if [[ ! -f local.nix ]]; then
  echo "error: $repository/local.nix is missing; see docs/setup/new-mac.md" >&2
  exit 1
fi

export NIX_CONFIG_LOCAL="$repository/local.nix"
export SUDO_ASKPASS="$repository/scripts/sudo-askpass.sh"

if [[ -n "${NIX_CONFIG_SETUP_BOOTSTRAP:-}" ]]; then
  echo "error: install-only bootstrap is reserved for the interactive setup wizard, not routine rebuilding." >&2
  exit 1
fi

# Validate the backup's authentication before changing the running system.
# Connect variables take precedence over the service account in the CLI;
# reject an incompatible environment instead of stripping credentials.
vault=$(nix eval --impure --raw --expr \
  '(import (builtins.toPath (builtins.getEnv "NIX_CONFIG_LOCAL"))).onePassword.vault or ""')
if [[ -n "$vault" ]]; then
  if [[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
    echo "error: rebuilding with automatic backup requires the configured service-account environment; use the human setup workflow if credentials are missing." >&2
    exit 1
  fi
  if [[ -n "${OP_CONNECT_HOST:-}" || -n "${OP_CONNECT_TOKEN:-}" ]]; then
    echo "error: automatic backup requires the service-account environment, not a Connect environment; no credentials were changed." >&2
    exit 1
  fi
  op_bin=$(command -v op) || {
    echo "error: the configured 1Password CLI is unavailable." >&2
    exit 1
  }
  host_name=$(/usr/sbin/scutil --get LocalHostName)
  if [[ -z "$host_name" ]]; then
    echo "error: cannot identify this host's backup document." >&2
    exit 1
  fi
  doc_title="nix-config local.nix $host_name"
  backup_dir=$(umask 077; mktemp -d)
  trap 'rm -rf "$backup_dir"' EXIT
  if ! (umask 077; "$op_bin" document get "$doc_title" --vault "$vault" > "$backup_dir/stored" 2>/dev/null); then
    echo "error: backup authentication/read preflight failed; check service-account access and the setup-created document. Activation was not attempted; no fallback or document creation was attempted." >&2
    exit 1
  fi
fi

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
# every local.nix edit. Runs only after successful activation. A backup failure
# is reported as a failure, without switching accounts or creating another item.
#
# The vault comes FROM local.nix. It was hard-coded here until 2026-08-14, when
# an audit found the vault name — a private name — in four lines of this script
# and two of the wizard, in a public repository.
if [[ -z "$vault" ]]; then
  echo "==> No local.nix backup vault configured"
else
  if ! cmp -s local.nix "$backup_dir/stored"; then
    if ! "$op_bin" document edit "$doc_title" local.nix --vault "$vault" >/dev/null 2>&1; then
      echo "error: activation succeeded but the local.nix backup could not be updated." >&2
      exit 1
    fi
    if ! (umask 077; "$op_bin" document get "$doc_title" --vault "$vault" > "$backup_dir/verified" 2>/dev/null) \
      || ! cmp -s local.nix "$backup_dir/verified"; then
      echo "error: activation succeeded but the local.nix backup did not verify." >&2
      exit 1
    fi
    echo "==> Updated and verified the local.nix backup"
  else
    echo "==> Verified the local.nix backup is current"
  fi
fi
