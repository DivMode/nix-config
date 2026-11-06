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
# A second review found six more ways past it: flags before the command
# (`gh -Rowner/public pr comment` was exempt as if it were `gh --help`), a body
# or title that reads as `-R` and so named another repository, a duplicated -R,
# an alias (gh expands it, so its text and its -R were never seen), a command
# the guard does not know, and Git variables exported by whatever launched gh,
# which made every public checkout look like some other repository. So the
# command is now found the way gh finds it, a flag's value is never an option,
# an alias is expanded from `gh alias list` before anything is decided, and
# when it is unclear whether a word is an option the command is checked, not
# trusted.
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

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# "owner/name", lower-cased, from a slug, URL, or remote.
slug_of() {
  local value=${1%/}
  value=${value%.git}
  value=${value##*:}
  value=$(printf '%s' "$value" | awk -F/ 'NF >= 2 { print $(NF - 1) "/" $NF }')
  lower "$value"
}

# gh's own command groups. A group not named here is an alias, an extension, or
# a command newer than this list: it is never taken for a read.
known_group() {
  case "$1" in
    agent-task | alias | api | attestation | auth | browse | cache | codespace | completion | config | \
      discussion | extension | gist | gpg-key | help | issue | label | org | pr | project | release | repo | \
      ruleset | run | search | secret | skill | ssh-key | status | variable | workflow) return 0 ;;
  esac
  return 1
}

# How a flag takes its value decides whether the next word is an option or a
# value, and a value is never an option: `-b '-Rowner/other'` is a body. The
# lists are of flags with one arity in every command (a flag that is a boolean
# in one command and takes a value in another is in neither). Any flag in
# neither list may take the next word, so that word is not trusted as an option.
takes_value() {
  case "$1" in
    -R | --repo | -b | --body | -F | --body-file | -t | --title | -H | -X | -q | -B | -A | -S | -L | -T | -a | -l | \
      --notes | --notes-file | --assignee | --label | --reviewer | --base | --head | --milestone | --project | \
      --template | --jq | --json | --search | --state | --limit | --author | --hostname | --input | --field | \
      --raw-field | --header | --method | --cache | --preview | --name | --branch | --target | --subject | \
      --description | --discussion-category | --notes-start-tag | --reason | --ref | --workflow | --sort | \
      --order | --visibility | --topic | --language | --message) return 0 ;;
  esac
  return 1
}
never_takes_value() {
  case "$1" in
    --draft | --web | -w | --fill | --fill-first | --fill-verbose | --dry-run | --no-maintainer-edit | \
      --prerelease | --generate-notes | --verify-tag | --editor | -e | --paginate | --slurp | --silent | \
      --verbose | --include | -i | --help | -h | --version | --squash | --merge | --admin | --auto | \
      --delete-branch | --yes) return 0 ;;
  esac
  return 1
}

# Find the command in $args the way gh does: the group is the first word that
# is not a flag or a flag's value, the action the next. gh accepts flags before
# either (`gh -R owner/repo pr comment`, `gh pr -R owner/repo create`).
#   group, group_index, action
#   flag_before_action  a flag other than -R came first, and could have taken the
#                       next word: never a read then (`gh pr -t list create` is
#                       `pr create` titled "list")
#   real_repos          what -R/--repo names where it is surely an option
scan_command() {
  group="" group_index=-1 action="" flag_before_action=false
  real_repos=()
  local i arg value positionals=0 unsure=false literal=false
  for (( i = 0; i < ${#args[@]}; i++ )); do
    arg=${args[i]}
    if ! $literal; then
      case "$arg" in
        --)
          literal=true
          continue
          ;;
        -R | --repo)
          $unsure || real_repos+=("${args[i + 1]:-}")
          i=$(( i + 1 ))
          unsure=false
          continue
          ;;
        --repo=*)
          $unsure || real_repos+=("${arg#--repo=}")
          unsure=false
          continue
          ;;
        -R?*)
          value=${arg#-R}
          $unsure || real_repos+=("${value#=}")
          unsure=false
          continue
          ;;
        --*=* | -?=*)
          (( positionals >= 2 )) || flag_before_action=true
          unsure=false
          continue
          ;;
        --* | -?)
          (( positionals >= 2 )) || flag_before_action=true
          if takes_value "$arg"; then
            i=$(( i + 1 ))
            unsure=false
          elif never_takes_value "$arg"; then
            unsure=false
          else
            unsure=true
          fi
          continue
          ;;
        -?*)
          # An attached value (-bText) or combined flags (-de).
          (( positionals >= 2 )) || flag_before_action=true
          if takes_value "${arg:0:2}"; then unsure=false; else unsure=true; fi
          continue
          ;;
      esac
    fi
    unsure=false
    positionals=$(( positionals + 1 ))
    if (( positionals == 1 )); then
      group=$arg
      group_index=$i
    elif (( positionals == 2 )); then
      action=$arg
    fi
  done
}

# Split an alias expansion into words the way a shell would, without running
# anything: quotes group, a backslash escapes, nothing is expanded.
alias_words=()
split_words() { # <string> → $alias_words
  alias_words=()
  local text=$1 word="" started=false quote="" ch i
  for (( i = 0; i < ${#text}; i++ )); do
    ch=${text:i:1}
    if [[ -n "$quote" ]]; then
      if [[ "$ch" == "$quote" ]]; then
        quote=""
      elif [[ "$ch" == "\\" && "$quote" == '"' ]]; then
        i=$(( i + 1 ))
        word+=${text:i:1}
      else
        word+=$ch
      fi
      continue
    fi
    case "$ch" in
      "'" | '"') quote=$ch; started=true ;;
      "\\") i=$(( i + 1 )); word+=${text:i:1}; started=true ;;
      [[:space:]])
        if $started; then
          alias_words+=("$word")
          word="" started=false
        fi
        ;;
      *) word+=$ch; started=true ;;
    esac
  done
  if $started; then alias_words+=("$word"); fi
}

# gh expands an alias itself, so what it posts is in its configuration, not in
# the arguments. `gh alias list` prints "name: expansion" from the local
# config: no network, no credentials. The expansion is printed as YAML (observed
# with gh 2.103.3): quoted when it holds ": " or starts with "!", and a block of
# indented lines when it spans several. Returns 1 when there is no such alias
# and 2 when the list cannot be read.
alias_expansion() { # <name> → $expansion
  local listing line collecting=false
  expansion=""
  listing=$("$real_gh" alias list 2>/dev/null) || return 2
  while IFS= read -r line; do
    if $collecting; then
      [[ "$line" == [[:space:]]* ]] || return 0
      line=${line#"${line%%[![:space:]]*}"}
      expansion+="${expansion:+ }$line"
    elif [[ "$line" == "$1: "* ]]; then
      expansion=${line#"$1: "}
      case "$expansion" in
        \|* | \>*)
          expansion=""
          collecting=true
          ;;
        \'*\')
          expansion=${expansion#\'}
          expansion=${expansion%\'}
          return 0
          ;;
        \"*\")
          expansion=${expansion#\"}
          expansion=${expansion%\"}
          return 0
          ;;
        *) return 0 ;;
      esac
    fi
  done <<< "$listing"
  $collecting
}

scan_command

# A word that is not one of gh's groups is an alias (or an extension, or
# something unknown), and it is not a read until shown to be one: expanded here,
# its text is checked and its own -R and command are found.
unresolved=false
if [[ -n "$group" ]] && ! known_group "$group"; then
  unresolved=true
  status=0
  alias_expansion "$group" || status=$?
  case "$status" in
    0)
      if [[ "$expansion" == '!'* ]]; then
        # A shell alias runs arbitrary shell; any gh it calls comes back here.
        args+=("$expansion")
      else
        split_words "$expansion"
        typed=("${args[@]}")
        args=()
        for (( i = 0; i < ${#typed[@]}; i++ )); do
          if (( i == group_index )); then
            for (( j = 0; j < ${#alias_words[@]}; j++ )); do args+=("${alias_words[j]}"); done
          else
            args+=("${typed[i]}")
          fi
        done
        scan_command
        if known_group "$group"; then unresolved=false; fi
      fi
      ;;
    1) ;;
    *)
      echo "gh: refused — \"$group\" is not a built-in command, and gh could not list its aliases to say whether it is one." >&2
      exit 1
      ;;
  esac
fi

# Commands that cannot post anything to a repository.
case "$group" in
  "" | auth | alias | completion | config | extension | help | search | status | browse | \
    codespace | org | ssh-key | gpg-key | attestation)
    exec "$real_gh" "$@"
    ;;
  api) ;;
  *)
    if ! $flag_before_action && ! $unresolved; then
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
  for (( i = 0; i < ${#args[@]}; i++ )); do
    (( i == group_index )) && continue
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
    for (( i = 0; i < ${#args[@]}; i++ )); do
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
  # Git variables exported by whatever launched gh (GIT_DIR from a hook in a
  # linked worktree, say) would answer for that repository instead of this
  # checkout, so every public checkout would resolve to the same origin.
  slug=$(slug_of "$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR \
    git -C "$public_checkout" remote get-url origin 2>/dev/null)")
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
#
# A public repository named by ANY -R/--repo word counts, wherever it stands,
# and however many there are: whichever of them gh uses, and whether the word is
# an option or a value that only reads like one, the text is checked. Only
# scan_command's real_repos can show that the command is aimed elsewhere.
candidates=()
for (( i = 0; i < ${#args[@]}; i++ )); do
  arg=${args[i]}
  for slug in "${publics[@]}"; do
    public_url_re="^((https?|ssh)://)?(git@)?(www\\.)?github\\.com[/:]${slug//./\\.}(\\.git)?([/#?].*)?$"
    [[ "$(lower "$arg")" =~ $public_url_re ]] && target=$slug
  done
  case "$arg" in
    -R | --repo) candidates+=("${args[i + 1]:-}") ;;
    --repo=*) candidates+=("${arg#--repo=}") ;;
    -R?*) value=${arg#-R}; candidates+=("${value#=}") ;;
  esac
done
for (( i = 0; i < ${#candidates[@]}; i++ )); do
  if is_public "$(slug_of "${candidates[i]}")"; then break; fi
done

aimed_at_cwd() {
  local j remote
  if (( ${#real_repos[@]} > 0 )); then
    for (( j = 0; j < ${#real_repos[@]}; j++ )); do
      if is_public "$(slug_of "${real_repos[j]}")"; then return 0; fi
    done
    return 1
  fi
  if [[ -n "${GH_REPO:-}" ]]; then
    is_public "$(slug_of "$GH_REPO")"
    return
  fi
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
