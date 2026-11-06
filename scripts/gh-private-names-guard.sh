#!/usr/bin/env bash
#
# gh, guarded: refuse to post a private name to a public repository.
#
# The pre-push hook keeps private names out of what `git push` publishes, but
# pull request titles and bodies, comments, issues, and release notes never
# pass through git. On 2026-10-09 nine of nix-config's pull requests were
# found naming private projects, seven of them from the week before.
#
# The public repositories are nix-config and the other projects local.nix lists
# in publicProjects; every other one is private. local.nix already says where
# each is checked out, so that is the whole of the visibility rule: no question
# put to GitHub, only each public checkout's origin. A command that can post to
# a public repository has its text checked by scripts/check-private-names.sh
# --text before gh runs.
#
# It fails closed, because the first version of this file did not. Review
# found fifteen ways past a list of WRITE subcommands — gh's aliases (pr new,
# release new), text-carrying commands it did not name (pr revert, issue
# develop), a PR URL given from another checkout, attached short flags
# (-RDivMode/x, -F<file>) — so the list here is of READS, and anything else
# aimed at a public repository, or at a repository it cannot identify, is
# checked.
#
# It wraps gh itself rather than hooking one agent client, so Claude Code,
# Codex, and any script reach GitHub through the same check.
#
# Installed as `gh` by modules/home/development.nix, which sets:
#   GH_GUARD_REAL_GH    the real gh
#   GH_GUARD_CHECKOUT   nix-config's main checkout, where the check script lives
#   GH_GUARD_CHECKOUTS  every public repository's checkout (nix-config's too),
#                       separated by newlines or colons

set -euo pipefail

real_gh=${GH_GUARD_REAL_GH:?}
checkout=${GH_GUARD_CHECKOUT:?}
checkouts=${GH_GUARD_CHECKOUTS:?}
args=("$@")
group=${args[0]:-}

# The action is the first word after the group that is not a flag, since gh
# takes flags before it too (`gh pr -R <repo> create`). -R/--repo is skipped
# with its value. Any other flag there could be taking the next word as its
# value — `gh pr -t list create` is `pr create` titled "list" — so the command
# is then never treated as a read.
action=""
flag_before_action=false
for (( i = 1; i < ${#args[@]}; i++ )); do
  case "${args[i]}" in
    -R | --repo) i=$(( i + 1 )) ;;
    --repo=* | -R?*) ;;
    -*) flag_before_action=true ;;
    *) action=${args[i]}; break ;;
  esac
done

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
    if ! $flag_before_action; then
      case "$group:$action" in
        *: | *:list | *:ls | *:view | *:status | *:diff | *:checks | *:checkout | *:co | \
          *:download | *:verify | *:verify-asset | *:watch | *:get | *:set-default | \
          *:gitignore | *:license | repo:clone | gist:clone)
          exec "$real_gh" "$@"
          ;;
      esac
    fi
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

  # A GraphQL call is a mutation unless it is shown to be a query: a query
  # field given inline or in a readable file that never says `mutation` as a
  # word. Locating the operation keyword exactly means parsing comments,
  # commas, and strings; a query that merely mentions the word is checked
  # instead, which costs a second and blocks nothing clean. A body sent with
  # --input, or anything read from stdin, counts as a mutation too.
  if [[ "$endpoint" == graphql ]]; then
    query="" known=false
    for (( i = 1; i < ${#args[@]}; i++ )); do
      arg=${args[i]}
      case "$arg" in
        --input | --input=*) known=false; break ;;
        -f | -F | --field | --raw-field) value=${args[i + 1]:-}; i=$(( i + 1 )) ;;
        --field=* | --raw-field=*) value=${arg#*=} ;;
        -f?* | -F?*) value=${arg#-?} ;;
        *) continue ;;
      esac
      [[ "$value" == query=* ]] || continue
      value=${value#query=}
      if [[ "$value" == @* ]]; then
        if [[ "$value" == @- || ! -f "${value#@}" ]]; then
          known=false
          break
        fi
        value=$(cat "${value#@}")
      fi
      query=$value
      known=true
    done
    if $known && ! printf '%s\n' "$query" | grep -Eq '(^|[^A-Za-z0-9_])mutation([^A-Za-z0-9_]|$)'; then
      exec "$real_gh" "$@"
    fi
  fi
fi

# "owner/name" of every public repository, from its checkout's origin. One that
# cannot be identified refuses the command, as the single one always did: with
# it unknown, nothing says the command is not aimed at it.
publics=()
while IFS= read -r public_checkout; do
  [[ -n "$public_checkout" ]] || continue
  slug=$(slug_of "$(git -C "$public_checkout" remote get-url origin 2>/dev/null)")
  if [[ -z "$slug" ]]; then
    echo "gh: refused — cannot tell which repository is public: $public_checkout has no origin remote." >&2
    exit 1
  fi
  publics+=("$slug")
done <<< "${checkouts//:/$'\n'}"
if (( ${#publics[@]} == 0 )); then
  echo "gh: refused — cannot tell which repository is public: GH_GUARD_CHECKOUTS names no checkout." >&2
  exit 1
fi

# The public repositories the command is aimed at, once known. Several only
# when it names no repository at all (below).
target=""
is_public() { # <owner/name> → true, and sets $target, when it is a public repository
  local slug
  for slug in "${publics[@]}"; do
    if [[ "$slug" == "$1" ]]; then
      target=$slug
      return 0
    fi
  done
  return 1
}

# Which repository is this aimed at? An argument that IS a URL of one (gh takes
# the repository from a PR or issue URL), -R, GH_REPO, the API endpoint, or
# else the current checkout, whose remotes gh resolves. A URL merely quoted
# inside a body does not count: linking a public repository from a private
# one's comment is not posting to it.
repo_flag=""
for (( i = 0; i < ${#args[@]}; i++ )); do
  arg=${args[i]}
  for slug in "${publics[@]}"; do
    public_url_re="^((https?|ssh)://)?(git@)?(www\\.)?github\\.com[/:]${slug//./\\.}(\\.git)?([/#?].*)?$"
    [[ "$(lower "$arg")" =~ $public_url_re ]] && target=$slug
  done
  case "$arg" in
    -R | --repo) repo_flag=${args[i + 1]:-} ;;
    --repo=*) repo_flag=${arg#--repo=} ;;
    -R?*) repo_flag=${arg#-R}; repo_flag=${repo_flag#=} ;;
  esac
done
repo_flag=${repo_flag:-${GH_REPO:-}}

aimed_at_cwd() {
  if [[ -n "$repo_flag" ]]; then
    is_public "$(slug_of "$repo_flag")"
    return
  fi
  local remote
  while IFS= read -r remote; do
    is_public "$(slug_of "$(git remote get-url "$remote")")" && return 0
  done < <(git remote 2>/dev/null)
  return 1
}

if [[ -z "$target" ]]; then
  if [[ "$group" == api ]]; then
    if [[ "$endpoint" == repos/* ]]; then
      named=$(printf '%s' "$endpoint" | cut -d/ -f2-3)
      if [[ "$named" == *"{owner}"* || "$named" == *"{repo}"* ]]; then
        aimed_at_cwd || true
      else
        is_public "$named" || true
      fi
    else
      # graphql, repositories/<id>, user, gists: no repository named, so
      # it could be any of them.
      printf -v target '%s, ' "${publics[@]}"
      target=${target%, }
    fi
  else
    aimed_at_cwd || true
  fi
fi
[[ -n "$target" ]] || exec "$real_gh" "$@"

# Everything that will be posted. An argument naming a file is checked by the
# file's contents and its name, not its directory: a session's scratch path can
# itself contain a private project's name and is never posted, while the name
# of an uploaded release asset is. Text read from stdin is kept and handed to
# gh afterwards.
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
text="$work_dir/text"
: > "$text"
stdin_copy=""

for arg in "${args[@]}"; do
  case "$arg" in
    -e | --editor)
      echo "gh: refused — text written in an editor cannot be checked before it is posted to $target; pass it with --body or --body-file." >&2
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
    printf '\n%s\n%s\n' "${arg/"$file"/}" "$(basename "$file")" >> "$text"
  else
    printf '%s\n' "$arg" >> "$text"
  fi
done

if ! "$checkout/scripts/check-private-names.sh" --text "gh $group $action" < "$text"; then
  echo "gh: refused — nothing was posted to public repository $target." >&2
  exit 1
fi

# An editor's text would reach GitHub unchecked, however the editor was asked
# for (-e, --editor, or combined short flags such as -de), so gh gets one that
# fails. GH_EDITOR takes precedence over every other editor setting.
export GH_EDITOR=false

# Not exec: the trap must still remove the copies once gh is done.
status=0
if [[ -n "$stdin_copy" ]]; then
  "$real_gh" "$@" < "$stdin_copy" || status=$?
else
  "$real_gh" "$@" || status=$?
fi
exit "$status"
