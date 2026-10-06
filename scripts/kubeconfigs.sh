#!/usr/bin/env bash
#
# Kubeconfigs that a project's own recipe writes to ~/.kube/<name>.
#
# local.nix declares them, because the project that owns each cluster is private:
#
#   kubeconfigs."<name>" = { project = "<key in projects>"; recipe = "<just recipe>"; };
#
# A kubeconfig is not desired configuration, so nothing here stores one. It is
# re-derived on demand by the project that created the cluster. A new Mac had none,
# and nothing said where it came from (2026-10-06).
#
#   --check    warn about each missing kubeconfig and the command that writes it
#              (rebuild.sh runs this; it never fails a rebuild)
#   --restore  run the owning project's recipe for each missing kubeconfig
#              (setup-mac.sh runs this). A project not yet cloned is reported, not fatal.
set -euo pipefail

mode="${1:-}"
case "$mode" in
  --check | --restore) ;;
  *)
    echo "usage: $0 --check | --restore" >&2
    exit 2
    ;;
esac

repository="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
local_file="${NIX_CONFIG_LOCAL:-$repository/local.nix}"

# One "<name>\t<project path>\t<recipe>" line per declared kubeconfig. A project key
# that local.nix's `projects` does not define fails the evaluation, loudly.
entries=$(LOCAL_PATH="$local_file" nix eval --impure --raw --expr '
  let
    local = import (builtins.toPath (builtins.getEnv "LOCAL_PATH"));
    declared = local.kubeconfigs or { };
    line = name: "${name}\t${local.projects.${declared.${name}.project}}\t${declared.${name}.recipe}";
  in
  builtins.concatStringsSep "\n" (map line (builtins.attrNames declared))
')
[[ -n "$entries" ]] || exit 0

status=0
while IFS=$'\t' read -r name project recipe; do
  file="$HOME/.kube/$name"
  [[ -f "$file" ]] && continue
  command="just --justfile $project/justfile $recipe"
  if [[ "$mode" == --check ]]; then
    echo "warning: $file is missing; write it with: $command" >&2
    continue
  fi
  if [[ ! -f "$project/justfile" ]]; then
    echo "warning: $file is missing and $project is not cloned yet; after cloning, run: $command" >&2
    continue
  fi
  echo "==> writing $file ($command)"
  # mise supplies the project's own Node; its recipes evaluate with it.
  if ! (cd "$project" && mise exec -- just "$recipe") || [[ ! -f "$file" ]]; then
    echo "error: $command did not write $file" >&2
    status=1
  fi
done <<<"$entries"
exit "$status"
