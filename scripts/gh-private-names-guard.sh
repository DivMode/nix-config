#!/usr/bin/env bash
#
# gh, guarded: refuse to post a private name to this public repository.
#
# The pre-push hook keeps private names out of what `git push` publishes, but
# pull request titles and bodies, comments, issues, and release notes never
# pass through git. On 2026-10-09 nine of this repository's pull requests were
# found naming private projects, seven of them from the week before.
#
# This repository is the one public repository; every other one is private.
# local.nix already says which checkout this is (projects.nixconfig), so that
# is the whole of the visibility rule: no list of public repositories and no
# question put to GitHub. A write aimed here has its text checked by
# scripts/check-private-names.sh --text; every read, and every write anywhere
# else, runs gh untouched.
#
# It wraps gh itself rather than hooking one agent client, so Claude Code,
# Codex, and any script reach GitHub through the same check.
#
# Installed as `gh` by modules/home/development.nix, which sets:
#   GH_GUARD_REAL_GH   the real gh
#   GH_GUARD_CHECKOUT  this repository's main checkout

set -euo pipefail

real_gh=${GH_GUARD_REAL_GH:?}
checkout=${GH_GUARD_CHECKOUT:?}
args=("$@")
group=${args[0]:-}
action=${args[1]:-}

# "owner/name", lower-cased, from a slug, URL, or remote.
slug_of() {
  local value=${1%/}
  value=${value%.git}
  value=${value##*:}
  value=$(printf '%s' "$value" | awk -F/ 'NF >= 2 { print $(NF - 1) "/" $NF }')
  printf '%s' "$value" | tr '[:upper:]' '[:lower:]'
}

# Does this invocation change anything on GitHub?
write=false
case "$group" in
  pr | issue)
    case "$action" in create | edit | comment | review | merge | close | reopen) write=true ;; esac
    ;;
  release | label)
    case "$action" in create | edit) write=true ;; esac
    ;;
  repo)
    [[ "$action" == edit ]] && write=true
    ;;
  api)
    method="" fields=false
    for (( i = 1; i < ${#args[@]}; i++ )); do
      case "${args[i]}" in
        -X | --method) method=${args[i + 1]:-} ;;
        --method=*) method=${args[i]#--method=} ;;
        -f | -F | --field | --raw-field | --input | --field=* | --raw-field=* | --input=*) fields=true ;;
      esac
    done
    method=$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')
    if [[ -n "$method" ]]; then
      [[ "$method" != GET ]] && write=true
    else
      $fields && write=true
    fi
    ;;
esac
$write || exec "$real_gh" "$@"

public=$(slug_of "$(git -C "$checkout" remote get-url origin 2>/dev/null)") || public=""
if [[ -z "$public" ]]; then
  echo "gh: refused — cannot tell which repository is public: $checkout has no origin remote." >&2
  exit 1
fi

# Which repository is this aimed at? An explicit -R or GH_REPO decides it;
# otherwise gh uses the current checkout, so any of its remotes counts.
repo_flag=""
for (( i = 0; i < ${#args[@]}; i++ )); do
  case "${args[i]}" in
    -R | --repo) repo_flag=${args[i + 1]:-} ;;
    --repo=*) repo_flag=${args[i]#--repo=} ;;
  esac
done
repo_flag=${repo_flag:-${GH_REPO:-}}

aimed_at_cwd() {
  if [[ -n "$repo_flag" ]]; then
    [[ "$(slug_of "$repo_flag")" == "$public" ]]
    return
  fi
  local remote
  while IFS= read -r remote; do
    [[ "$(slug_of "$(git remote get-url "$remote")")" == "$public" ]] && return 0
  done < <(git remote 2>/dev/null)
  return 1
}

target=false
if [[ "$group" == api ]]; then
  endpoint=""
  for (( i = 1; i < ${#args[@]}; i++ )); do
    case "${args[i]}" in
      -X | --method | -f | -F | --field | --raw-field | --input | -H | --header | \
        -q | --jq | -t | --template | --cache | -p | --preview | --hostname)
        i=$(( i + 1 )) ;;
      -*) ;;
      *) endpoint=${args[i]}; break ;;
    esac
  done
  endpoint_lower=$(printf '%s' "$endpoint" | tr '[:upper:]' '[:lower:]')
  if [[ "$endpoint_lower" == *"repos/$public"* ]]; then
    target=true
  elif [[ "$endpoint" == *"{owner}"* || "$endpoint" == *"{repo}"* || "$endpoint_lower" == graphql ]]; then
    aimed_at_cwd && target=true
  fi
else
  aimed_at_cwd && target=true
fi
$target || exec "$real_gh" "$@"

# Everything that will be posted: the arguments, and the files they name.
# Text read from stdin is kept and handed to gh afterwards.
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
text="$work_dir/text"
stdin_copy=""
printf '%s\n' "${args[@]}" > "$text"

add_file() {
  if [[ "$1" == - ]]; then
    if [[ -z "$stdin_copy" ]]; then
      stdin_copy="$work_dir/stdin"
      cat > "$stdin_copy"
    fi
    cat "$stdin_copy" >> "$text"
  elif [[ -f "$1" ]]; then
    cat "$1" >> "$text"
  else
    echo "gh: refused — cannot read \"$1\" to check it for private names." >&2
    exit 1
  fi
}

for (( i = 0; i < ${#args[@]}; i++ )); do
  arg=${args[i]}
  next=${args[i + 1]:-}
  case "$group:$arg" in
    pr:-F | pr:--body-file | issue:-F | issue:--body-file | release:-F | release:--notes-file | api:--input)
      add_file "$next" ;;
    pr:--body-file=* | issue:--body-file=* | release:--notes-file=* | api:--input=*)
      add_file "${arg#*=}" ;;
    api:-F | api:--field)
      [[ "$next" == *=@* ]] && add_file "${next#*=@}" ;;
    api:--field=*)
      [[ "$arg" == *=@* ]] && add_file "${arg#*=@}" ;;
  esac
done

if ! "$checkout/scripts/check-private-names.sh" --text "gh $group $action" < "$text"; then
  echo "gh: refused — $public is public; nothing was posted." >&2
  exit 1
fi

# Not exec: the trap must still remove the copies once gh is done.
status=0
if [[ -n "$stdin_copy" ]]; then
  "$real_gh" "$@" < "$stdin_copy" || status=$?
else
  "$real_gh" "$@" || status=$?
fi
exit "$status"
