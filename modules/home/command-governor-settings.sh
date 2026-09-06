#!/usr/bin/env bash
# Install Command Governor's harness settings into Prime Agent's GLOBAL
# settings.json, without replacing malformed or unmanaged state.
#
# The declared value is read from the Command Governor checkout HERE, at
# activation time, not baked into the Nix store at evaluation time. That
# repository owns the package list: pins/pins.json is its single source of
# truth for every version and its conformance suite asserts settings.project.json
# agrees with it. A copy in nix-config would be a second authority that nothing
# checks, and it would go stale the moment the pin moves. nix-config owns only
# the fact that Prime reads that configuration globally on this machine.
#
# Called through Home Manager's `run`, so a dry-run never enters this writer.
set -euo pipefail

jq_bin="${1:?jq path required}"
checkout="${2:?Command Governor checkout required}"
directory="${3:?agent directory required}"
harness_settings="$checkout/harness/settings.project.json"
settings="$directory/settings.json"

if [[ ! -f "$harness_settings" ]]; then
  cat >&2 <<EOF
Command Governor's harness settings are missing:
  $harness_settings

local.nix declares the checkout at $checkout. Clone the repository to that
path (and run its scripts/bootstrap.sh) or drop the projects.commandgovernor
entry. Refusing to install a global Prime Agent configuration that would not
match the product.
EOF
  exit 1
fi

# settings.project.json is written for <project>/.prime/agent/settings.json, so
# its vendored entries are relative to THAT directory -- `../../pins/...`
# resolves back to the checkout root. Installed globally the file sits at
# ~/.prime/agent/, where Prime resolves a user-scope relative package against
# getBaseDirForScope("user") == the agent dir (dist/core/package-manager.js),
# so the identical string would point at ~/pins/... and silently load nothing.
# Every relative entry is therefore rewritten to an absolute path into the
# checkout. `npm:` specifiers are left alone; Prime installs those itself.
#
# Any other spelling -- a bare `./x`, an absolute path, a git URL -- is a form
# this rewrite has never seen. Guessing would point the global settings
# somewhere plausible and wrong, so it fails the activation and says which
# entry it could not resolve.
if ! declared="$(
  "$jq_bin" -e --arg checkout "$checkout" '
    if type != "object" then
      error("settings.project.json is not a JSON object")
    else . end
    | .packages
    | if type != "array" then
        error("settings.project.json has no packages array")
      else . end
    | map(
        if type != "string" then
          error("package entry is not a string: " + tostring)
        elif startswith("npm:") then .
        elif startswith("../../") then $checkout + "/" + .[6:]
        else
          error("package entry is neither an npm: specifier nor a ../../ path relative to <project>/.prime/agent/: " + .)
        end
      )
    | { packages: . }
  ' "$harness_settings"
)"; then
  echo "Refusing to install a global Prime Agent configuration from $harness_settings." >&2
  exit 1
fi

if [[ -L "$directory" || (-e "$directory" && ! -d "$directory") ]]; then
  echo "Prime settings directory is unmanaged; refusing activation." >&2
  exit 1
fi
mkdir -p "$directory"
lock="$directory/.nix-config-settings.lock"
if ! mkdir "$lock" 2>/dev/null; then
  echo "Prime settings activation is already locked; inspect the existing lock before retrying." >&2
  exit 1
fi
temporary=""
cleanup() {
  [[ -z "$temporary" ]] || rm -f "$temporary"
  rmdir "$lock"
}
trap cleanup EXIT

read_current() {
  if [[ -L "$settings" || (-e "$settings" && ! -f "$settings") ]]; then
    echo "Prime settings are not a regular file; refusing to replace unmanaged state." >&2
    return 1
  fi
  if [[ -e "$settings" ]]; then
    if ! "$jq_bin" -e 'type == "object"' "$settings" >/dev/null 2>&1; then
      echo "Existing Prime settings are not a valid JSON object; preserving them unchanged." >&2
      return 1
    fi
    "$jq_bin" --sort-keys '.' "$settings"
  else
    printf '{}\n'
  fi
}

# `*` merges objects recursively and REPLACES arrays, which is the wanted
# behaviour: the harness owns `packages` outright, and everything Prime writes
# for itself (telemetry acknowledgement, recent models, auth migration) survives.
#
# The tradeoff is the one modules/home/ai/default.nix already documents for
# Claude Code: dropping an entry from the harness's `packages` removes it here,
# because the whole array is replaced, but a whole KEY that stops being declared
# is left behind, since a merge cannot tell "this is no longer declared" from
# "Prime wrote this".
current="$(read_current)"
merged="$(printf '%s' "$current" | "$jq_bin" --sort-keys --argjson declared "$declared" '. * $declared')"
if [[ "$current" != "$merged" || ! -e "$settings" ]]; then
  temporary=$(mktemp "$directory/.settings.nix-config.XXXXXX")
  # 0600 rather than 0644: Prime creates this file 0600 and it is the same file
  # its auth migration used to read apiKeys from. Do not widen it.
  chmod 0600 "$temporary"
  printf '%s\n' "$merged" >"$temporary"
  # Prime owns the remaining keys. Refuse a detected concurrent application edit.
  if [[ "$(read_current)" != "$current" ]]; then
    echo "Prime settings changed during activation; preserving the newer application state." >&2
    exit 1
  fi
  mv "$temporary" "$settings"
  temporary=""
fi
chmod 0600 "$settings"
