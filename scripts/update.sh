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
# script prints exactly what moved, builds it, and only then activates.
#
#   ./scripts/update.sh                       # every input
#   ./scripts/update.sh homebrew-cask         # just the Homebrew casks
#   ./scripts/update.sh --dry-run             # update the lock, do not activate
#
# Most declared casks carry Homebrew's `auto_updates` flag and update themselves,
# so they are unaffected either way. The ones that depend on this are the casks
# with no self-updater — currently claude-code and 1password-cli.

set -euo pipefail

repository="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository"

if [[ ! -f local.nix ]]; then
  echo "error: $repository/local.nix is missing; see docs/setup/new-mac.md" >&2
  exit 1
fi

export NIX_CONFIG_LOCAL="$repository/local.nix"

dryRun=false
inputs=()
for argument in "$@"; do
  case "$argument" in
    --dry-run) dryRun=true ;;
    -*)
      echo "error: unknown option $argument" >&2
      exit 1
      ;;
    *) inputs+=("$argument") ;;
  esac
done

host="${HOST:-example-mac}"

# Keep the pre-update lock so the summary below reports what actually changed
# rather than what was requested.
lockBefore="$(mktemp)"
trap 'rm -f "$lockBefore"' EXIT
cp flake.lock "$lockBefore"

if (( ${#inputs[@]} == 0 )); then
  echo "==> Updating every input"
  nix flake update
else
  echo "==> Updating: ${inputs[*]}"
  nix flake update "${inputs[@]}"
fi

if /usr/bin/cmp -s "$lockBefore" flake.lock; then
  echo "==> Already current; nothing moved"
  exit 0
fi

echo
echo "==> Inputs that moved"
git --no-pager diff --stat -- flake.lock || true

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
  echo "    Review the flake.lock diff, then run ./scripts/rebuild.sh"
  exit 0
fi

echo
echo "==> Activating"
exec "$repository/scripts/rebuild.sh" "$host"
