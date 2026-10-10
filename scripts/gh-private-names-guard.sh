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
# question put to GitHub. A command that can post to this repository has its
# text checked by scripts/check-private-names.sh --text before gh runs.
#
# It fails closed, because the first version of this file did not. Review
# found fifteen ways past a list of WRITE subcommands — gh's aliases (pr new,
# release new), text-carrying commands it did not name (pr revert, issue
# develop), a PR URL given from another checkout, attached short flags
# (-RDivMode/x, -F<file>) — so the list here is of READS, and anything else
# aimed at this repository, or at a repository it cannot identify, is checked.
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

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# "owner/name", lower-cased, from a slug, URL, or remote.
slug_of() {
  local value=${1%/}
  value=${value%.git}
  value=${value##*:}
  value=$(printf '%s' "$value" | awk -F/ 'NF >= 2 { print $(NF - 1) "/" $NF }')
  lower "$value"
}

# Commands that cannot post anything to a repository.
case "$group" in
  "" | -* | auth | alias | completion | config | extension | help | search | status | browse | \
    codespace | org | ssh-key | gpg-key | attestation)
    exec "$real_gh" "$@"
    ;;
  api) ;;
  *)
    case "$action" in
      "" | -* | list | ls | view | status | diff | checks | checkout | co | download | \
        verify | verify-asset | watch | get | clone | set-default | gitignore | license)
        exec "$real_gh" "$@"
        ;;
    esac
    ;;
esac

# An API call posts only when it sends a body or names a method other than
# GET; a GraphQL call posts only when it is a mutation, since queries are POSTs
# too. A mutation addresses its object by node ID, so its repository is unknown.
endpoint=""
if [[ "$group" == api ]]; then
  method="" fields=false
  for (( i = 1; i < ${#args[@]}; i++ )); do
    arg=${args[i]}
    case "$arg" in
      -X | --method) method=${args[i + 1]:-}; i=$(( i + 1 )) ;;
      --method=*) method=${arg#--method=} ;;
      -X*) method=${arg#-X} ;;
      -f | -F | --field | --raw-field | --input) fields=true; i=$(( i + 1 )) ;;
      -f* | -F* | --field=* | --raw-field=* | --input=*) fields=true ;;
      -H | --header | -q | --jq | -t | --template | --cache | -p | --preview | --hostname) i=$(( i + 1 )) ;;
      -*) ;;
      *) [[ -z "$endpoint" ]] && endpoint=$arg ;;
    esac
  done
  method=$(lower "${method#=}")
  if [[ -n "$method" ]]; then
    [[ "$method" == get ]] && exec "$real_gh" "$@"
  else
    $fields || exec "$real_gh" "$@"
  fi
  endpoint=$(lower "${endpoint#/}")
  if [[ "$endpoint" == graphql ]] && ! printf '%s\n' "${args[@]}" | grep -q mutation; then
    query_file=$(printf '%s\n' "${args[@]}" | sed -n 's/^\(-[fF]\)\{0,1\}query=@//p' | head -n1)
    if [[ -z "$query_file" || ! -f "$query_file" ]] || ! grep -q mutation "$query_file"; then
      exec "$real_gh" "$@"
    fi
  fi
fi

public=$(slug_of "$(git -C "$checkout" remote get-url origin 2>/dev/null)") || public=""
if [[ -z "$public" ]]; then
  echo "gh: refused — cannot tell which repository is public: $checkout has no origin remote." >&2
  exit 1
fi

# Which repository is this aimed at? A URL or -R naming it, GH_REPO, the API
# endpoint, or else the current checkout, whose remotes gh resolves.
target=false
repo_flag=""
for (( i = 0; i < ${#args[@]}; i++ )); do
  arg=${args[i]}
  case "$(lower "$arg")" in
    *"github.com/$public"* | *"github.com:$public"*) target=true ;;
  esac
  case "$arg" in
    -R | --repo) repo_flag=${args[i + 1]:-} ;;
    --repo=*) repo_flag=${arg#--repo=} ;;
    -R?*) repo_flag=${arg#-R}; repo_flag=${repo_flag#=} ;;
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

if ! $target; then
  if [[ "$group" == api ]]; then
    if [[ "$endpoint" == repos/* ]]; then
      named=$(printf '%s' "$endpoint" | cut -d/ -f2-3)
      if [[ "$named" == *"{owner}"* || "$named" == *"{repo}"* ]]; then
        aimed_at_cwd && target=true
      elif [[ "$named" == "$public" ]]; then
        target=true
      fi
    else
      # graphql, repositories/<id>, user, gists: no repository named, so
      # it could be this one.
      target=true
    fi
  else
    aimed_at_cwd && target=true
  fi
fi
$target || exec "$real_gh" "$@"

# Everything that will be posted. An argument naming a file is checked by the
# file's contents, not its path: a session's scratch path can itself contain a
# private project's name, and that path is never posted. Text read from stdin
# is kept and handed to gh afterwards.
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
text="$work_dir/text"
: > "$text"
stdin_copy=""

for arg in "${args[@]}"; do
  case "$arg" in
    -e | --editor)
      echo "gh: refused — text written in an editor cannot be checked before it is posted to $public; pass it with --body or --body-file." >&2
      exit 1
      ;;
  esac
  if [[ "$arg" == - || "$arg" == *=- || "$arg" == *@- || "$arg" =~ ^-[A-Za-z]-$ ]]; then
    if [[ -z "$stdin_copy" ]]; then
      stdin_copy="$work_dir/stdin"
      cat > "$stdin_copy"
      cat "$stdin_copy" >> "$text"
    fi
    continue
  fi
  file=""
  for candidate in "${arg#*=@}" "${arg#*=}" "${arg#-?=}" "${arg#-?}" "$arg"; do
    if [[ -n "$candidate" && -f "$candidate" ]]; then
      file=$candidate
      break
    fi
  done
  if [[ -n "$file" ]]; then
    cat "$file" >> "$text"
    printf '\n%s\n' "${arg/"$file"/}" >> "$text"
  else
    printf '%s\n' "$arg" >> "$text"
  fi
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
