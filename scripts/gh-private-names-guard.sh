#!/usr/bin/env bash
#
# gh, guarded: refuse to post a private name to a public repository.
#
# WHAT THIS GUARD GUARANTEES
#   It stops private names in text this wrapper can see from reaching a public
#   repository through gh commands. The private names are derived at run time
#   from the ignored local.nix, by scripts/check-private-names.sh. A command
#   goes to gh unchecked only when it is a read, cannot post to a repository
#   (auth, config, search...), or can be shown to write only to private
#   repositories. Anything else is treated as a write to a public repository,
#   and every piece of text the wrapper can reach is checked first: the
#   arguments, the files gh will read or upload, and standard input (kept, and
#   handed to gh again byte for byte).
#
#   It fails closed. Where it cannot decide - a flag or command it does not
#   know, a repository it cannot identify, a write whose destination is not a
#   repository (gists, projects, user and organization settings), an upload it
#   cannot read or that is binary - it treats the write as public. An
#   occasional refusal is the price; the alternative is a leak.
#
#   Text gh composes itself is not text the wrapper can see: the commit
#   messages behind `pr create --fill`, `--fill-first` and `--fill-verbose`, a
#   saved failed run (`--recover`), an issue template (`issue create
#   --template`), a release's tag annotation (`--notes-from-tag`) and the notes
#   GitHub generates (`--generate-notes`). Toward a public or possibly public
#   repository `--fill*` is refused unless --title and --body (or a --body-file
#   with a nonempty value) are given, since those take precedence; the others are refused outright,
#   because explicit text does not replace what they add.
#
#   It does NOT stop opaque code: gh extensions, shell aliases and `gh
#   copilot` run programs it cannot read, so they are let through only when
#   their command line is clean AND nothing but private repositories is in
#   reach, and it cannot see what such a program then does or reads (its
#   standard input is not read). It does not stop scripts that call the
#   GitHub API without gh, text typed into gh's own prompts, the files `git
#   push` publishes (scripts/hooks/pre-push does that), or a determined bypass
#   such as running the real gh by its store path.
#
# WHY IT EXISTS
# The pre-push hook keeps private names out of what `git push` publishes, but
# pull request titles and bodies, comments, issues, and release notes never
# pass through git. On 2026-10-09 nine of nix-config's pull requests were
# found naming private projects, seven of them from the week before.
#
# The public repositories are nix-config and the other projects local.nix lists
# in publicProjects; every other one is private. local.nix already says where
# each is checked out, so that is the whole of the visibility rule: no question
# put to GitHub, only each public checkout's origin.
#
# It wraps gh itself rather than hooking one agent client, so Claude Code,
# Codex, and any script reach GitHub through the same check.
#
# HOW IT DECIDES
#   1. The command is found the way gh finds it (cobra's rule: a flag in front
#      of the command takes the next word unless it is known not to), then
#      aliases are expanded from `gh alias list`: multi-word names, longest
#      first, found across flags and under any spelling of a group (`cs post`
#      is `codespace post`), `$1`..`$n` substituted and the rest appended, as
#      gh does. This comes before any exemption below: an alias can be filed
#      beneath a group that cannot post (`config post`). Where no alias is
#      found exactly but the group has some, they are inspected as if typed
#      and nothing exempts the command.
#   2. A genuine help request (-h, or --help whose last value is true: `--help
#      --help=false` runs the command), `gh help`, and commands that cannot
#      post to a repository go to gh at once; so do reads.
#   3. Flags are then read with the arity of THIS command (the tables below: a
#      word after a flag that takes a value is that value, never an option, a
#      file or a repository). A flag the tables do not know leaves the command
#      "unsure": no repository word can then prove a destination private, it
#      can only make it public.
#   4. The destination is proven private only from a -R that was surely an
#      option, GH_REPO, or a current checkout none of whose remotes is public;
#      positional repositories, URLs, gists, projects, organization and user
#      settings and an API call that names no repository are resolved per
#      command. A destination that cannot be proven private is inspected.
#   5. Text is read as text unless the option consuming it is a file option
#      (--body-file, --input, -F key=@file, release assets...), and only then
#      is the file opened. Uploads that are binary or unreadable are refused:
#      their contents cannot be checked reliably.
#
# The command and flag tables are generated from `gh <command> --help` of the
# pinned gh (2.103.3): a flag whose help line names a type takes a value. A
# gh that adds a flag only makes commands "unsure" until the tables catch up.
#
# Installed as `gh` by modules/home/development.nix, which sets:
#   GH_GUARD_REAL_GH    the real gh
#   GH_GUARD_CHECKOUT   nix-config's main checkout, where the check script lives
#   GH_GUARD_CHECKOUTS  every public repository's checkout (nix-config's too),
#                       separated by newlines or colons

set -euo pipefail

# Bash 5.2 reads & in a ${var//pattern/replacement} replacement as the match.
shopt -u patsub_replacement 2>/dev/null || true

real_gh=${GH_GUARD_REAL_GH:?}
checkout=${GH_GUARD_CHECKOUT:?}
checkouts=${GH_GUARD_CHECKOUTS:?}
args=("$@")

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

refuse() { # <reason>
  echo "gh: refused — $*" >&2
  exit 1
}

# "owner/name", lower-cased, from a slug, URL, or remote.
slug_of() {
  local value=${1%/}
  value=${value%.git}
  value=${value##*:}
  value=$(printf '%s' "$value" | awk -F/ 'NF >= 2 { print $(NF - 1) "/" $NF }')
  lower "$value"
}

# ---------------------------------------------------------------------------
# What gh has: groups, commands, and the arity of their flags.
# ---------------------------------------------------------------------------

# gh's own command groups, help topics included. A word not named here is an
# alias, an extension, or a command newer than this list: never a read.
known_group() {
  case "$1" in
    accessibility | actions | agent-task | alias | api | attestation | auth | browse | cache | codespace | \
      completion | config | discussion | environment | exit-codes | extension | formatting | gist | \
      gpg-key | help | issue | label | licenses | mintty | org | pr | preview | project | reference | \
      release | repo | ruleset | run | search | secret | skill | ssh-key | status | telemetry | variable | \
      workflow) return 0 ;;
  esac
  return 1
}

# Groups that cannot post anything to a repository, and the help topics.
no_post_group() {
  case "$1" in
    "" | accessibility | actions | alias | attestation | auth | browse | codespace | completion | config | \
      environment | exit-codes | formatting | gpg-key | help | licenses | mintty | org | preview | \
      reference | search | ssh-key | status | telemetry) return 0 ;;
  esac
  return 1
}

# gh's own short names for a group, as gh spells them in `gh <command> --help`
# ALIASES: <group word> → $canonical_name.
canonical_name=""
canonical_group() {
  case "$1" in
    agent-tasks | agent | agents) canonical_name=agent-task ;;
    at) canonical_name=attestation ;;
    cs) canonical_name=codespace ;;
    ext | extensions) canonical_name=extension ;;
    rs) canonical_name=ruleset ;;
    skills) canonical_name=skill ;;
    a11y) canonical_name=accessibility ;;
    *) canonical_name=$1 ;;
  esac
}

canonicalize() {
  if [[ "$group" == api ]]; then
    pair=api
    return 0
  fi
  canonical_group "$group"
  group=$canonical_name
  case "$group:$action" in
    *:ls) action=list ;;
    *:new) action=create ;;
    pr:co) action=checkout ;;
    secret:remove | variable:remove) action=delete ;;
    extension:uninstall) action=remove ;;
    skill:add) action=install ;;
    skill:show) action=preview ;;
  esac
  pair=$group
  [[ -z "$action" ]] || pair+=" $action"
}

# Does gh have this command? (Not an alias or an extension: gh refuses to
# define an alias over a command, so a command that exists is never one.)
command_exists() {
  [[ -n "$group" ]] || return 0
  known_group "$group" || return 1
  [[ -n "$action" ]] || return 0
  case "$group" in
    api | browse | completion | help | status | licenses | accessibility | actions | environment | \
      exit-codes | formatting | mintty | reference | telemetry) return 0 ;;
  esac
  case "$group $action" in
      "agent-task create" | "agent-task list" | "agent-task view" | "alias delete" | "alias import" | \
      "alias list" | "alias set" | "attestation download" | "attestation trusted-root" | \
      "attestation verify" | "auth login" | "auth logout" | "auth refresh" | "auth setup-git" | \
      "auth status" | "auth switch" | "auth token" | "cache delete" | "cache list" | "codespace code" | \
      "codespace cp" | "codespace create" | "codespace delete" | "codespace edit" | "codespace jupyter" | \
      "codespace list" | "codespace logs" | "codespace ports" | "codespace rebuild" | "codespace ssh" | \
      "codespace stop" | "codespace view" | "config clear-cache" | "config get" | "config list" | \
      "config set" | "discussion comment" | "discussion create" | "discussion edit" | "discussion list" | \
      "discussion view" | "extension browse" | "extension create" | "extension exec" | "extension install" | \
      "extension list" | "extension remove" | "extension search" | "extension upgrade" | "gist clone" | \
      "gist create" | "gist delete" | "gist edit" | "gist list" | "gist rename" | "gist view" | \
      "gpg-key add" | "gpg-key delete" | "gpg-key list" | "issue artifact" | "issue close" | \
      "issue comment" | "issue create" | "issue delete" | "issue develop" | "issue edit" | "issue list" | \
      "issue lock" | "issue pin" | "issue reopen" | "issue status" | "issue transfer" | "issue unlock" | \
      "issue unpin" | "issue view" | "label clone" | "label create" | "label delete" | "label edit" | \
      "label list" | "org list" | "pr checkout" | "pr checks" | "pr close" | "pr comment" | "pr create" | \
      "pr diff" | "pr edit" | "pr list" | "pr lock" | "pr merge" | "pr ready" | "pr reopen" | "pr revert" | \
      "pr review" | "pr status" | "pr unlock" | "pr update-branch" | "pr view" | "preview prompter" | \
      "project close" | "project copy" | "project create" | "project delete" | "project edit" | \
      "project field-create" | "project field-delete" | "project field-list" | "project item-add" | \
      "project item-archive" | "project item-create" | "project item-delete" | "project item-edit" | \
      "project item-list" | "project link" | "project list" | "project mark-template" | "project unlink" | \
      "project view" | "release create" | "release delete" | "release delete-asset" | "release download" | \
      "release edit" | "release list" | "release upload" | "release verify" | "release verify-asset" | \
      "release view" | "repo archive" | "repo autolink" | "repo clone" | "repo create" | "repo delete" | \
      "repo deploy-key" | "repo edit" | "repo fork" | "repo gitignore" | "repo license" | "repo list" | \
      "repo read-dir" | "repo read-file" | "repo rename" | "repo set-default" | "repo sync" | \
      "repo unarchive" | "repo view" | "ruleset check" | "ruleset list" | "ruleset view" | "run cancel" | \
      "run delete" | "run download" | "run list" | "run rerun" | "run view" | "run watch" | "search code" | \
      "search commits" | "search issues" | "search prs" | "search repos" | "secret delete" | "secret list" | \
      "secret set" | "skill install" | "skill list" | "skill preview" | "skill publish" | "skill search" | \
      "skill update" | "ssh-key add" | "ssh-key delete" | "ssh-key list" | "variable delete" | \
      "variable get" | "variable list" | "variable set" | "workflow disable" | "workflow enable" | \
      "workflow list" | "workflow run" | "workflow view") return 0 ;;
  esac
  return 1
}

# Commands that only read, or only change local state. `gh pr`, with no
# action, prints help.
read_command() {
  case "$group:$action" in
    *: | *:list | *:view | *:status | *:diff | *:checks | *:checkout | *:download | *:verify | *:verify-asset | \
      *:watch | *:get | *:set-default | *:gitignore | *:license | *:read-file | *:read-dir | \
      *:field-list | *:item-list | ruleset:check | skill:search | repo:clone | gist:clone) return 0 ;;
  esac
  return 1
}

# Is the arity of this command's flags in the tables below?
arity_known() {
  case "$group" in
    api) return 0 ;;
    agent-task | cache | discussion | gist | issue | label | pr | project | release | repo | ruleset | run | \
      secret | skill | variable | workflow) ;;
    *) return 1 ;;
  esac
  [[ -n "$action" ]] || return 1
  case "$action" in
    artifact | autolink | deploy-key | gitignore | license) return 1 ;;
  esac
  command_exists
}

# How a flag takes its value decides whether the next word is an option or a
# value, and a value is never an option: `-b '-Rowner/other'` is a body, and
# `variable set -e -Rowner/repo` names an environment. The same letter means
# different things to different commands (-e is --editor for pr create and
# --env for variable set), so this is per command, in $pair.
#   0  takes a value
#   1  never does
#   2  not known for this command: the next word may or may not be its value
flag_arity() { # <flag>
  case "$1" in
    --help) return 1 ;;
    -R | --repo) return 0 ;;
  esac
  arity_known || return 2
  case "$1" in
    # -h is help, except for the homepage.
    -h)
      case "$pair" in
        "repo create" | "repo edit") return 0 ;;
      esac
      return 1
      ;;
    # Flags whose arity depends on the command.
    -a)
      case "$pair" in
        "cache delete" | "pr review" | "run list" | "workflow list") return 1 ;;
      esac
      return 0
      ;;
    -c)
      case "$pair" in
        "discussion view" | "issue develop" | "issue view" | "pr review" | "pr status" | "pr view" | \
        "repo create") return 1 ;;
      esac
      return 0
      ;;
    -d)
      case "$pair" in
        "pr close" | "pr create" | "pr list" | "pr merge" | "pr revert" | "release create" | "run rerun") return 1 ;;
      esac
      return 0
      ;;
    -e)
      case "$pair" in
        "issue comment" | "issue create" | "pr comment" | "pr create") return 1 ;;
      esac
      return 0
      ;;
    -f)
      case "$pair" in
        "label clone" | "label create" | "pr checkout" | "pr create" | "skill install") return 1 ;;
      esac
      return 0
      ;;
    -i)
      case "$pair" in
        "api") return 1 ;;
      esac
      return 0
      ;;
    -l)
      case "$pair" in
        "issue develop") return 1 ;;
      esac
      return 0
      ;;
    -m)
      case "$pair" in
        "pr merge") return 1 ;;
      esac
      return 0
      ;;
    -p)
      case "$pair" in
        "gist create" | "release create" | "ruleset list" | "ruleset view") return 1 ;;
      esac
      return 0
      ;;
    -r)
      case "$pair" in
        "gist view" | "pr merge" | "pr review") return 1 ;;
      esac
      return 0
      ;;
    -s)
      case "$pair" in
        "pr merge") return 1 ;;
      esac
      return 0
      ;;
    -u)
      case "$pair" in
        "repo clone" | "run list") return 0 ;;
      esac
      return 1
      ;;
    -v)
      case "$pair" in
        "repo set-default" | "run view") return 1 ;;
      esac
      return 0
      ;;
    -w)
      case "$pair" in
        "run list") return 0 ;;
      esac
      return 1
      ;;
    --comment)
      case "$pair" in
        "pr review") return 1 ;;
      esac
      return 0
      ;;
    --json)
      case "$pair" in
        "workflow run") return 1 ;;
      esac
      return 0
      ;;
    --remote)
      case "$pair" in
        "repo fork") return 1 ;;
      esac
      return 0
      ;;
    --source)
      case "$pair" in
        "repo list") return 1 ;;
      esac
      return 0
      ;;
    --template)
      case "$pair" in
        "repo edit") return 1 ;;
      esac
      return 0
      ;;
    --user)
      case "$pair" in
        "run list") return 0 ;;
      esac
      return 1
      ;;
    # Flags that mean the same in every command.
    -A | -B | -b | -D | -F | -g | -H | -j | -k | -L | -n | -O | -o | -q | -S | -T | -t | -X | --add | \
      --add-assignee | --add-blocked-by | --add-blocking | --add-label | --add-project | --add-reviewer | \
      --add-sub-issue | --add-topic | --after | --agent | --app | --archive | --assignee | --attach | \
      --attempt | --author | --author-email | --base | --blocked-by | --blocking | --body | --body-file | \
      --branch | --branch-repo | --cache | --category | --color | --commit | --created | --custom-agent | \
      --data-type | --date | --default-branch | --desc | --description | --dir | --discussion-category | \
      --duplicate-of | --env | --env-file | --event | --exclude | --field | --field-id | --filename | \
      --filter | --fork-name | --format | --from-file | --gitignore | --head | --header | --homepage | \
      --hostname | --id | --input | --interval | --iteration-id | --job | --jq | --key | --label | \
      --language | --license | --limit | --match-head-commit | --mention | --method | --milestone | --name | \
      --notes | --notes-file | --notes-start-tag | --number | --order | --org | --output | --owner | \
      --page | --parent | --pattern | --pin | --preview | --project | --project-id | --query | --raw-field | \
      --readme | --reason | --recover | --ref | --remote-name | --remove | --remove-assignee | \
      --remove-blocked-by | --remove-blocking | --remove-label | --remove-project | --remove-reviewer | \
      --remove-sub-issue | --remove-topic | --repos | --reviewer | --scope | --search | \
      --single-select-option-id | --single-select-options | --sort | --source-owner | \
      --squash-merge-commit-message | --state | --status | --subject | --tag | --target | --target-owner | \
      --team | --text | --title | --topic | --type | --upstream-remote-name | --url | --visibility | \
      --workflow | --worktree) return 0 ;;
    -y | --accept-visibility-change-consequences | --add-readme | --admin | --all | \
      --allow-escape-sequences | --allow-forking | --allow-hidden-dirs | --allow-update-branch | \
      --answered | --approve | --archived | --auto | --checkout | --cleanup-tag | --clear | --clobber | \
      --clone | --closed | --comments | --compact | --conflict-status | --create-if-none | --debug | \
      --default | --default-branch-only | --delete | --delete-branch | --delete-branch-on-merge | \
      --delete-last | --detach | --disable-auto | --disable-issues | --disable-wiki | --draft | --drafts | \
      --dry-run | --edit | --edit-last | --editor | --enable-advanced-security | --enable-auto-merge | \
      --enable-discussions | --enable-issues | --enable-merge-commit | --enable-projects | \
      --enable-rebase-merge | --enable-secret-scanning | --enable-secret-scanning-push-protection | \
      --enable-squash-merge | --enable-wiki | --exclude-drafts | --exclude-pre-releases | --exit-status | \
      --fail-fast | --fail-on-no-commits | --failed | --files | --fill | --fill-first | --fill-verbose | \
      --fix | --follow | --force | --fork | --from-local | --generate-notes | --include | \
      --include-all-branches | --include-content | --internal | --latest | --list | --log | --log-failed | \
      --merge | --name-only | --no-archived | --no-maintainer-edit | --no-repos-selected | --no-store | \
      --no-upstream | --notes-from-tag | --paginate | --parents | --patch | --prerelease | --private | \
      --public | --push | --raw | --rebase | --recurse-submodules | --remove-milestone | --remove-parent | \
      --remove-type | --request-changes | --required | --secret | --silent | --skip-existing | --slurp | \
      --squash | --succeed-on-no-caches | --undo | --unpin | --unset | --upstream | --value | --verbose | \
      --verify-tag | --view | --watch | --web | --yaml | --yes) return 1 ;;
  esac
  return 2
}

# What a word given to a flag is: text (the default) that will be posted as
# it stands, a file gh reads (its contents are posted), an upload (a file, then
# `#label`), or a field (`key=value`, or `key=@file` read from a file).
value_kind() { # <flag> → $kind
  kind=text
  case "$1" in
    --body-file | --notes-file | --from-file | --env-file | --input) kind="file" ;;
    --attach) kind=asset ;;
    -F)
      case "$pair" in
        api | "workflow run") kind=field ;;
        *) kind="file" ;;
      esac
      ;;
    --field)
      case "$pair" in
        api | "workflow run") kind=field ;;
      esac
      ;;
    -f)
      case "$pair" in
        "secret set" | "variable set") kind="file" ;;
      esac
      ;;
    -T | --template)
      [[ "$pair" != "pr create" ]] || kind="file"
      ;;
    -a | --add)
      [[ "$pair" != "gist edit" ]] || kind="file"
      ;;
  esac
}

# What a positional word is, by its place among the positional words.
positional_kind() { # <position> → $kind
  kind=text
  case "$pair" in
    "gist create") kind="file" ;;
    "release create" | "release upload") (( $1 == 0 )) || kind=asset ;;
    "skill publish") kind=asset ;;
  esac
}

# ---------------------------------------------------------------------------
# Finding the command.
# ---------------------------------------------------------------------------

# The group is the first word that is not a flag or a flag's value, the action
# the next (cobra's rule: a flag it does not know takes the next word). gh
# accepts flags before either (`gh -R owner/repo pr comment`, `gh pr -R
# owner/repo create`). `-h` is one it does not know: gh defines only `--help`,
# and pflag answers a stray `-h` with help itself, so the word after `-h` is
# taken (observed with gh 2.103.3: `gh config -h x post` runs the alias `config
# post`, `gh config --help x post` prints config's help).
#   group, group_index, action, action_index, pair
#   flag_before_action  a flag other than -R or --help came first, and could
#                       have taken the next word: never a read then (`gh pr -t
#                       list create` is `pr create` titled "list"), and never
#                       proof of a private destination
find_command() {
  group="" group_index=-1 action="" action_index=-1 pair="" flag_before_action=false
  local i arg n=${#args[@]} literal=false flag_before_group=false
  for (( i = 0; i < n; i++ )); do
    arg=${args[i]}
    if ! $literal; then
      case "$arg" in
        --)
          literal=true
          continue
          ;;
        --help | --version) continue ;;
        -R | --repo)
          i=$(( i + 1 ))
          continue
          ;;
        --repo=* | -R?*) continue ;;
        --*=*)
          flag_before_action=true
          [[ -n "$group" ]] || flag_before_group=true
          continue
          ;;
        --* | -?)
          flag_before_action=true
          [[ -n "$group" ]] || flag_before_group=true
          i=$(( i + 1 ))
          continue
          ;;
        -?*)
          flag_before_action=true
          [[ -n "$group" ]] || flag_before_group=true
          continue
          ;;
      esac
    fi
    if [[ -z "$group" ]]; then
      group=$arg
      group_index=$i
    else
      action=$arg
      action_index=$i
      break
    fi
  done
  canonicalize
  # An API call's second word is its endpoint, not an action, and the flags
  # between are its own (-X POST repos/...): read with api's arity below.
  if [[ "$group" == api ]]; then
    action_index=-1
    flag_before_action=$flag_before_group
  fi
}

# Read every argument with this command's flag arity.
#   role[i]   cmd (the group or action), flag, value (taken by the flag before
#             it), attached (-bText, --body=Text), pos
#   opt[i]    for a flag, value or attached: the flag, with -R for --repo
#   val[i]    the value of an attached flag, or the word itself for a value
#   repo_words        what every -R/--repo was given
#   real_repos        those that were surely options: no flag of unknown arity
#                     just before them, which might have taken them as its value
#   any_unsure        some flag's arity is not known: no repository word can
#                     then prove a destination private
#   help_flag         a genuine help request: -h (where it is help), or --help
#                     whose last value is true, that is not somebody's value
#   st_*              the last value of the boolean flags the decision turns
#                     on, as note_bool() keeps it: on, off or maybe
role=() opt=() val=() pos_idx=() real_repos=() repo_words=()
any_unsure=false help_flag=false unsure=false short_help=false
st_help=off st_fill=off st_fill_first=off st_fill_verbose=off
st_generate_notes=off st_notes_from_tag=off
ai=0

# One more occurrence of a boolean flag. pflag lets the last value win and takes
# any strconv.ParseBool spelling (observed with gh 2.103.3: `--help --help=false`
# goes on to run the command, `--help=false --help` prints help, `--help=T`
# does too, and a value that is not a ParseBool spelling is an error that posts
# nothing). A word after a flag of unknown arity might be that flag's value
# rather than an option, so what it says may or may not count: the state is
# then "maybe", which grants nothing and refuses what a fill would.
note_bool() { # <state variable> <value>
  local var=$1 old=${!1} new
  case "$2" in
    1 | t | T | TRUE | true | True) new=on ;;
    *) new=off ;;
  esac
  if $unsure && [[ "$new" != "$old" ]]; then new=maybe; fi
  printf -v "$var" '%s' "$new"
}

note_flag() { # <flag> <value>
  case "$1" in
    --help) note_bool st_help "$2" ;;
    --fill) note_bool st_fill "$2" ;;
    -f)
      if [[ "$pair" == "pr create" ]]; then note_bool st_fill "$2"; fi
      ;;
    --fill-first) note_bool st_fill_first "$2" ;;
    --fill-verbose) note_bool st_fill_verbose "$2" ;;
    --generate-notes) note_bool st_generate_notes "$2" ;;
    --notes-from-tag) note_bool st_notes_from_tag "$2" ;;
  esac
}

note_repo() { # <value of -R>
  repo_words+=("$1")
  $unsure || real_repos+=("$1")
}

# The word after the flag at index $ai is its value.
take_value() { # <flag>
  local next=$(( ai + 1 ))
  (( next < ${#args[@]} )) || return 0
  if (( next == group_index || next == action_index )); then
    any_unsure=true
    return 0
  fi
  ai=$next
  role[ai]=value
  opt[ai]=$1
  val[ai]=${args[ai]}
  if [[ "$1" == -R ]]; then note_repo "${args[ai]}"; fi
}

parse_args() {
  role=() opt=() val=() pos_idx=() real_repos=() repo_words=()
  any_unsure=$flag_before_action help_flag=false unsure=false short_help=false
  st_help=off st_fill=off st_fill_first=off st_fill_verbose=off
  st_generate_notes=off st_notes_from_tag=off
  local n=${#args[@]} arg name rest c j rc literal=false uncertain
  for (( ai = 0; ai < n; ai++ )); do
    arg=${args[ai]}
    role[ai]=pos opt[ai]="" val[ai]=""
    if (( ai == group_index || ai == action_index )); then
      role[ai]=cmd
      unsure=false
      continue
    fi
    if ! $literal; then
      case "$arg" in
        --)
          literal=true
          role[ai]=flag
          unsure=false
          continue
          ;;
        -R | --repo)
          role[ai]=flag opt[ai]=-R
          take_value -R
          unsure=false
          continue
          ;;
        --repo=*)
          role[ai]=attached opt[ai]=-R val[ai]=${arg#--repo=}
          note_repo "${val[ai]}"
          unsure=false
          continue
          ;;
        -R?*)
          rest=${arg#-R}
          role[ai]=attached opt[ai]=-R val[ai]=${rest#=}
          note_repo "${val[ai]}"
          unsure=false
          continue
          ;;
        --*=*)
          name=${arg%%=*}
          role[ai]=attached opt[ai]=$name val[ai]=${arg#*=}
          rc=0
          flag_arity "$name" || rc=$?
          if (( rc == 2 )); then any_unsure=true; fi
          note_flag "$name" "${arg#*=}"
          unsure=false
          continue
          ;;
        --* | -?)
          role[ai]=flag opt[ai]=$arg
          rc=0
          flag_arity "$arg" || rc=$?
          case "$rc" in
            0)
              take_value "$arg"
              unsure=false
              ;;
            1)
              # -h is pflag's own help request, which nothing after it cancels.
              if [[ "$arg" == -h ]] && ! $unsure; then short_help=true; fi
              note_flag "$arg" true
              unsure=false
              ;;
            *)
              any_unsure=true
              unsure=true
              ;;
          esac
          continue
          ;;
        -?*)
          # An attached value (-bText) or combined flags (-de).
          role[ai]=flag opt[ai]=$arg
          uncertain=false
          for (( j = 1; j < ${#arg}; j++ )); do
            c=-${arg:j:1}
            rc=0
            flag_arity "$c" || rc=$?
            if (( rc == 0 )); then
              rest=${arg:j+1}
              if [[ -n "$rest" ]]; then
                role[ai]=attached opt[ai]=$c val[ai]=${rest#=}
                if [[ "$c" == -R ]]; then note_repo "${val[ai]}"; fi
              else
                role[ai]=flag opt[ai]=$c
                take_value "$c"
              fi
              break
            elif (( rc == 1 )); then
              if [[ "$c" == -h ]] && ! $unsure; then short_help=true; fi
              if [[ "${arg:j+1:1}" == "=" && "$c" == -f ]]; then
                note_flag "$c" "${arg:j+2}"
                break
              fi
              note_flag "$c" true
            else
              any_unsure=true
              uncertain=true
              break
            fi
          done
          unsure=$uncertain
          continue
          ;;
      esac
    fi
    role[ai]=pos
    pos_idx+=("$ai")
    unsure=false
  done
  if $short_help || [[ "$st_help" == on ]]; then help_flag=true; fi
}

# Was this boolean flag given, bare (`--private`, not `--private=false`)?
has_bare_flag() { # <flag>
  local i
  for (( i = 0; i < ${#args[@]}; i++ )); do
    if [[ "${role[i]}" == flag && "${opt[i]}" == "$1" ]]; then return 0; fi
  done
  return 1
}

# The value of the last occurrence of one of these value-taking flags, as
# $last_val; false when none was given.
last_value() { # <flag>...
  local i f found=1
  last_val=""
  for (( i = 0; i < ${#args[@]}; i++ )); do
    [[ "${role[i]}" == value || "${role[i]}" == attached ]] || continue
    for f in "$@"; do
      if [[ "${opt[i]}" == "$f" ]]; then
        last_val=${val[i]}
        found=0
      fi
    done
  done
  return "$found"
}

# Does the command give a body of its own? --body does, whatever it says; a
# --body-file only when its last value is not empty, since gh reads the file
# (and counts the body as given) only for a nonempty name.
body_given() {
  has_opt -b --body && return 0
  last_value -F --body-file && [[ -n "$last_val" ]]
}

# Was one of these flags given (as a flag, not as somebody's value)?
has_opt() { # <flag>...
  local i f
  for (( i = 0; i < ${#args[@]}; i++ )); do
    [[ "${role[i]}" == flag || "${role[i]}" == attached ]] || continue
    for f in "$@"; do
      if [[ "${opt[i]}" == "$f" ]]; then return 0; fi
    done
  done
  return 1
}

# ---------------------------------------------------------------------------
# Aliases.
# ---------------------------------------------------------------------------

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
# indented lines when it spans several. A multi-word name prints as it is
# typed ("issue post: ..."). Returns 1 when there is no such alias.
alias_listing="" alias_listed=false
# Is this line of the listing the alias called <name>? gh files an alias beneath
# its command group under any spelling of the group, so `cs post` and
# `codespace post` are one alias (observed with gh 2.103.3: with `cs post` set,
# `gh codespace post` runs it).
alias_line_is() { # <line> <name>
  local key first
  [[ "$1" != [[:space:]]* && "$1" == *": "* ]] || return 1
  key=${1%%: *}
  [[ "$key" == "$2" ]] && return 0
  [[ "$key" == *" "* && "$2" == *" "* ]] || return 1
  canonical_group "${key%% *}"
  first=$canonical_name
  canonical_group "${2%% *}"
  [[ "$first" == "$canonical_name" && "${key#* }" == "${2#* }" ]]
}
load_aliases() {
  $alias_listed && return 0
  alias_listing=$("$real_gh" alias list 2>/dev/null) ||
    refuse "\"$group\" is not a built-in command, and gh could not list its aliases to say whether it is one."
  alias_listed=true
}
alias_expansion() { # <name> → $expansion
  local line collecting=false
  expansion=""
  while IFS= read -r line; do
    if $collecting; then
      [[ "$line" == [[:space:]]* ]] || return 0
      line=${line#"${line%%[![:space:]]*}"}
      expansion+="${expansion:+ }$line"
    elif alias_line_is "$line" "$1"; then
      expansion=${line#*: }
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
  done <<< "$alias_listing"
  $collecting
}

# gh's own rule (observed with gh 2.103.3): the alias is the longest name, of
# one or more words, found the way gh finds a subcommand: the group word, then
# the next word that is not a flag or a flag's value (find_command has located
# both), then the words right after. Every other argument, the flags between
# the words included, is passed on in order (`gh config --help=false post foo`
# runs the alias `config post` with `--help=false foo`). Each extra word replaces
# `$1`, `$2`... in turn in the expansion's TEXT, until no `$` is left, after
# which the remaining words are appended; the text is then split like a shell
# would. A shell alias (`!...`) runs `sh`.
#
# Where no alias matches exactly but the group is one of gh's own, gh may still
# reach an alias beneath it (a name of more words, or a flag this guard reads
# differently from gh). The group's aliases are then inspected as if typed and
# nothing exempts the command: alias_uncertain.
opaque="" alias_uncertain=false
expand_alias() {
  local name found=0 k j n=${#args[@]} idx=() consumed typed=() rest_args=() extra=() text placeholder line key
  load_aliases
  idx=("$group_index")
  if (( action_index >= 0 )); then
    idx+=("$action_index")
    for (( j = action_index + 1; j < n && ${#idx[@]} < 5; j++ )); do
      [[ "${args[j]}" != -* ]] || break
      idx+=("$j")
    done
  fi
  for (( k = ${#idx[@]}; k >= 1; k-- )); do
    name=""
    for (( j = 0; j < k; j++ )); do name+="${name:+ }${args[idx[j]]}"; done
    if alias_expansion "$name"; then
      found=$k
      break
    fi
  done
  if (( found > 0 )); then
    typed=("${args[@]}")
    for (( j = group_index + 1; j < n; j++ )); do
      consumed=false
      for (( k = 0; k < found; k++ )); do
        if (( idx[k] == j )); then consumed=true; fi
      done
      if ! $consumed; then rest_args+=("${typed[j]}"); fi
    done
    if [[ "$expansion" == '!'* ]]; then
      # A shell alias runs arbitrary shell; its text is checked with the rest.
      opaque="the shell alias \"$name\""
      split_words "$expansion"
      args+=("${alias_words[@]}")
      return 0
    fi
    text=$expansion
    for (( j = 0; j < ${#rest_args[@]}; j++ )); do
      if [[ "$text" == *'$'* ]]; then
        placeholder='$'$(( j + 1 ))
        text=${text//"$placeholder"/"${rest_args[j]}"}
      else
        extra+=("${rest_args[j]}")
      fi
    done
    split_words "$text"
    args=("${typed[@]:0:group_index}" "${alias_words[@]}")
    if (( ${#extra[@]} > 0 )); then args+=("${extra[@]}"); fi
    find_command
  elif known_group "$group"; then
    while IFS= read -r line; do
      [[ "$line" != [[:space:]]* && "$line" == *": "* ]] || continue
      key=${line%%: *}
      [[ "$key" == *" "* ]] || continue
      canonical_group "${key%% *}"
      [[ "$canonical_name" == "$group" ]] || continue
      if alias_expansion "$key"; then
        alias_uncertain=true
        if [[ "$expansion" == '!'* ]]; then opaque="the shell alias \"$key\""; fi
        split_words "$expansion"
        args+=("${alias_words[@]}")
      fi
    done <<< "$alias_listing"
  fi
  if ! command_exists && ! known_group "$group"; then
    opaque="\"$group\" (an extension, or a command this guard does not know)"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Where is it going?
# ---------------------------------------------------------------------------

# "owner/name" of every public repository, from its checkout's origin. One that
# cannot be identified refuses the command, as the single one always did: with
# it unknown, nothing says the command is not aimed at it.
publics=()
load_publics() {
  local public_checkout slug
  while IFS= read -r public_checkout; do
    [[ -n "$public_checkout" ]] || continue
    # Git variables exported by whatever launched gh (GIT_DIR from a hook in a
    # linked worktree, say) would answer for that repository instead of this
    # checkout, so every public checkout would resolve to the same origin.
    slug=$(slug_of "$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR \
      git -C "$public_checkout" remote get-url origin 2>/dev/null)")
    if [[ -z "$slug" ]]; then
      refuse "cannot tell which repository is public: $public_checkout has no origin remote."
    fi
    publics+=("$slug")
  done <<< "${checkouts//:/$'\n'}"
  if (( ${#publics[@]} == 0 )); then
    refuse "cannot tell which repository is public: GH_GUARD_CHECKOUTS names no checkout."
  fi
}

# The public repository the command is aimed at, once known.
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

# Is this whole word a public repository: [HOST/]OWNER/REPO, or its URL? A URL
# merely quoted inside a body is not the whole word and does not count: linking
# a public repository from a private one's comment is not posting to it.
names_public() { # <word> → true, and sets $target
  local word slug url_re slug_re
  word=$(lower "$1")
  for slug in "${publics[@]}"; do
    url_re="^((https?|ssh)://)?(git@)?(www\\.)?github\\.com[/:]${slug//./\\.}(\\.git)?([/#?].*)?$"
    slug_re="^([a-z0-9.-]+/)?${slug//./\\.}$"
    if [[ "$word" =~ $url_re || "$word" =~ $slug_re ]]; then
      target=$slug
      return 0
    fi
  done
  return 1
}

# The repository gh uses when none is named: GH_REPO, else the current
# checkout, whose remotes gh resolves. Sets $destination: public (and $target),
# private, or unknown (no remote to go by).
destination="unknown"
repo_of_environment() {
  local remote found=false
  if [[ -n "${GH_REPO:-}" ]]; then
    if is_public "$(slug_of "$GH_REPO")"; then destination=public; else destination=private; fi
    return 0
  fi
  while IFS= read -r remote; do
    found=true
    if is_public "$(slug_of "$(git remote get-url "$remote" 2>/dev/null)")"; then
      destination=public
      return 0
    fi
  done < <(git remote 2>/dev/null)
  if $found; then destination=private; else destination=unknown; fi
}

# private when the command is shown to write only to a private repository,
# public (and $target) when it names or defaults to a public one, else unknown.
# Only a flag that was surely an option, GH_REPO, or the current checkout can
# prove a destination private; a repository-like word can only make it public.
resolve_destination() {
  local i word sure=false endpoint named first
  destination=unknown target=""
  load_publics
  for (( i = 0; i < ${#args[@]}; i++ )); do
    [[ "${role[i]}" != flag ]] || continue
    word=${args[i]}
    if names_public "$word"; then break; fi
    if [[ "$word" == -*=* ]] && names_public "${word#*=}"; then break; fi
  done
  if [[ -z "$target" ]]; then
    for word in "${repo_words[@]}"; do
      if is_public "$(slug_of "$word")"; then break; fi
    done
  fi
  if [[ -n "$target" ]]; then
    destination=public
    return 0
  fi

  if [[ -n "$opaque" ]]; then
    # Nothing is known of what this will do with -R or anything else; only
    # where it is run from can say the destination is private.
    repo_of_environment
    return 0
  fi
  if arity_known && ! $any_unsure; then sure=true; fi
  $sure || return 0

  case "$group" in
    gist | project)
      # They address objects by ID or name, whatever the current directory.
      return 0
      ;;
    api)
      endpoint=$(lower "${api_endpoint#/}")
      if [[ "$endpoint" == repos/* ]]; then
        named=$(printf '%s' "$endpoint" | cut -d/ -f2-3)
        if [[ "$named" == *"{owner}"* || "$named" == *"{repo}"* ]]; then
          repo_of_environment
        elif is_public "$named"; then
          destination=public
        else
          destination=private
        fi
      fi
      # graphql, repositories/<id>, user, gists: no repository named, so it
      # could be any of them.
      return 0
      ;;
    variable | secret)
      # An organization's or a user's settings are not the current repository's.
      if has_opt -o --org -u --user; then return 0; fi
      ;;
    repo)
      case "$action" in
        create)
          # A new repository is private only when it is created so.
          if has_bare_flag --private; then destination=private; fi
          return 0
          ;;
        edit | delete | archive | unarchive | sync | fork)
          # The repository is the first positional word; without one, gh uses
          # the current repository. A bare name belongs to whoever is logged
          # in, which is not known here.
          if (( ${#pos_idx[@]} > 0 )); then
            first=${args[pos_idx[0]]}
            if [[ "$first" == */* ]]; then destination=private; fi
            return 0
          fi
          ;;
      esac
      ;;
  esac
  if (( ${#real_repos[@]} > 0 )); then
    destination=private
  else
    repo_of_environment
  fi
}

# ---------------------------------------------------------------------------
# What will be posted.
# ---------------------------------------------------------------------------

work_dir="" text="" stdin_copy=""

text_add() { printf '%s\n' "$1" >> "$text"; }

# Standard input is read once, kept for gh, and checked with the rest.
take_stdin() {
  if [[ -z "$stdin_copy" ]]; then
    stdin_copy="$work_dir/stdin"
    cat > "$stdin_copy"
    cat "$stdin_copy" >> "$text"
  fi
}

# Does the file hold a NUL byte? Text inspection of such a file is unreliable.
is_binary() { # <file>
  local without size
  without=$(LC_ALL=C tr -d '\000' < "$1" | wc -c)
  size=$(wc -c < "$1")
  (( without != size ))
}

# A file's contents, and its name: the name of an uploaded asset is posted, and
# the directory it came from is not (a session's scratch path can itself
# contain a private project's name). An upload must be readable text. A pipe
# or device (--body-file <(...), /dev/stdin) can be read only once, so it
# could not be checked and still reach gh whole.
add_file() { # <path> <read|upload>
  local path=$1
  if [[ -f "$path" && -r "$path" ]]; then
    if [[ "$2" == upload ]] && is_binary "$path"; then
      refuse "$path is a binary file, and the contents of a binary cannot be reliably checked before they are uploaded to $label."
    fi
    cat "$path" >> "$text"
    printf '\n' >> "$text"
    text_add "$(basename "$path")"
  elif [[ -e "$path" ]]; then
    refuse "$path is not a regular file that can be read (it may be a pipe, a device or a directory), so what gh takes from it cannot be checked before it is sent to $label."
  elif [[ "$2" == upload ]]; then
    refuse "$path cannot be read, so what is uploaded to $label cannot be checked."
  else
    text_add "$path"
  fi
}

add_value() { # <value> <kind>
  local value=$1 file
  case "$2" in
    file)
      if [[ "$value" == - ]]; then take_stdin; else add_file "$value" read; fi
      ;;
    asset)
      if [[ "$value" == *'#'* ]]; then text_add "${value#*#}"; fi
      add_file "${value%%#*}" upload
      ;;
    field)
      if [[ "$value" == *=@* ]]; then
        text_add "${value%%=*}"
        file=${value#*=@}
        if [[ "$file" == - ]]; then take_stdin; else add_file "$file" read; fi
      else
        text_add "$value"
      fi
      ;;
    *) text_add "$value" ;;
  esac
}

# Commands that read standard input although nothing on the command line says
# so (from gh's help): the text is on the pipe, and gh gets it again after.
implicit_stdin() {
  [[ ! -t 0 ]] || return 1
  case "$pair" in
    "workflow run") has_opt --json ;;
    "variable set" | "secret set") ! has_opt -b --body -f --env-file ;;
    "gist create") (( ${#pos_idx[@]} == 0 )) ;;
    *) return 1 ;;
  esac
}

# Everything that will be posted, when every flag's meaning is known.
collect_exact() {
  local i arg rc n=${#args[@]} kind position=0
  for (( i = 0; i < n; i++ )); do
    arg=${args[i]}
    case "${role[i]}" in
      flag)
        case "$arg" in
          -e | --editor)
            rc=0
            flag_arity "$arg" || rc=$?
            if (( rc != 0 )); then
              refuse "text written in an editor cannot be checked before it is posted to $label; pass it with --body or --body-file."
            fi
            ;;
        esac
        text_add "$arg"
        ;;
      value | attached)
        value_kind "${opt[i]}"
        if [[ "$kind" == text ]]; then text_add "$arg"; else add_value "${val[i]}" "$kind"; fi
        ;;
      pos)
        positional_kind "$position"
        position=$(( position + 1 ))
        if [[ "$kind" == text ]]; then text_add "$arg"; else add_value "$arg" "$kind"; fi
        ;;
      *) text_add "$arg" ;;
    esac
  done
}

# Everything that might be posted, when it is not known what a flag means: the
# words as they stand, and the contents of any that names a file, however it
# is attached.
collect_any() {
  local arg candidate
  for arg in "${args[@]}"; do
    case "$arg" in
      -e | --editor)
        refuse "text written in an editor cannot be checked before it is posted to $label; pass it with --body or --body-file."
        ;;
    esac
    if [[ "$arg" == - || "$arg" == *=- || "$arg" == *@- || "$arg" =~ ^-[A-Za-z]-$ ]]; then
      take_stdin
    fi
    text_add "$arg"
    for candidate in "${arg#*=@}" "${arg#*=}" "${arg#-?=}" "${arg#-?}" "${arg%%#*}" "$arg"; do
      if [[ -n "$candidate" && -f "$candidate" ]]; then
        cat "$candidate" >> "$text"
        printf '\n' >> "$text"
        text_add "$(basename "$candidate")"
        break
      fi
    done
  done
}

# Text gh composes from somewhere the wrapper cannot read: commit messages
# (`pr create --fill`, `--fill-first`, `--fill-verbose`), a saved failed run
# (`--recover`), an issue template named on the command line, a release's tag
# annotation or the notes GitHub generates. Explicit --title and --body take
# precedence over --fill (`gh pr create --help`), so with both the wrapper sees
# everything that is posted; a --body-file counts only with a nonempty last
# value, since gh treats an empty one as no body override and fills the body
# anyway. The others are not made safe by explicit text, or by anything the
# wrapper can see: gh rejects --template together with --body or
# --body-file, accepts --recover only in an interactive session, and adds
# --notes to the notes it generates. This runs only for a destination that is,
# or may be, public.
refuse_unseen_text() {
  local filling state
  case "$pair" in
    "pr create")
      if has_opt --recover; then
        refuse "pr create --recover takes text saved by a failed earlier run, which the guard cannot see; pass --title and --body explicitly"
      fi
      filling=false
      for state in "$st_fill" "$st_fill_first" "$st_fill_verbose"; do
        if [[ "$state" != off ]]; then filling=true; fi
      done
      if $filling && { $any_unsure || ! has_opt -t --title || ! body_given; }; then
        refuse "pr create --fill takes text from commit messages the guard cannot see; pass --title and --body explicitly"
      fi
      ;;
    "issue create")
      if has_opt --recover; then
        refuse "issue create --recover takes text saved by a failed earlier run, which the guard cannot see; pass --title and --body explicitly"
      fi
      if has_opt -T --template; then
        refuse "issue create --template takes its body from a template the guard cannot see; pass --body explicitly"
      fi
      ;;
    "release create")
      if [[ "$st_notes_from_tag" != off ]]; then
        refuse "release create --notes-from-tag takes its notes from a tag annotation or commit message the guard cannot see; pass --notes or --notes-file explicitly"
      fi
      if [[ "$st_generate_notes" != off ]]; then
        refuse "release create --generate-notes posts notes GitHub generates, which the guard cannot see; write them and pass --notes or --notes-file"
      fi
      ;;
  esac
}

# ---------------------------------------------------------------------------
# The decision.
# ---------------------------------------------------------------------------

find_command
[[ -n "$group" ]] || exec "$real_gh" "$@"

# A command gh does not have is an alias (expanded here, since gh does it
# itself and its text and -R would never be seen) or an extension or something
# unknown: not a read until shown to be one.
if ! command_exists; then expand_alias; fi

if [[ -z "$opaque" ]]; then
  if ! $alias_uncertain && no_post_group "$group"; then exec "$real_gh" "$@"; fi
  if [[ "$group" == extension ]]; then
    # Managing extensions is local. Running one is not: it is a program that
    # makes its own requests and never comes back through this wrapper.
    case "$action" in
      "" | browse | create | install | list | remove | search | upgrade) exec "$real_gh" "$@" ;;
      *) opaque="gh extension $action" ;;
    esac
  fi
fi

parse_args

# A genuine help request - -h (where gh does not use it for something else), or
# --help whose last value is true, that is not somebody's value - prints help
# and posts nothing. (An extension is another matter: gh hands it every
# argument, --help included; and words taken from an alias this guard could not
# pin down are not the user's.)
if [[ -z "$opaque" ]] && ! $alias_uncertain && $help_flag; then exec "$real_gh" "$@"; fi

if [[ -z "$opaque" && "$group" != api ]] && ! $flag_before_action && command_exists && read_command; then
  exec "$real_gh" "$@"
fi

# An API call posts only when it sends a body or names a method other than
# GET; a GraphQL call posts only when it is a mutation, since queries are POSTs
# too. A mutation addresses its object by node ID, so its repository is unknown.
api_endpoint=""
if [[ "$group" == api && -z "$opaque" ]]; then
  method="" fields=false query="" query_known=false
  for (( i = 0; i < ${#args[@]}; i++ )); do
    case "${role[i]}" in
      pos) [[ -n "$api_endpoint" ]] || api_endpoint=${args[i]} ;;
      value | attached)
        case "${opt[i]}" in
          -X | --method) method=${val[i]} ;;
          -f | -F | --field | --raw-field) fields=true ;;
          --input) fields=true ;;
        esac
        ;;
    esac
  done
  api_endpoint=${api_endpoint#/}
  # `-X GET` with a flag of unknown arity somewhere might not be the method.
  if ! $any_unsure; then
    method=$(lower "${method#=}")
    if [[ -n "$method" ]]; then
      [[ "$method" == get ]] && exec "$real_gh" "$@"
    else
      $fields || exec "$real_gh" "$@"
    fi

    # A GraphQL call is a mutation unless it is shown to be a query: a query
    # field given inline or in a readable file that never says `mutation` as a
    # word. Locating the operation keyword exactly means parsing comments,
    # commas, and strings; a query that merely mentions the word is checked
    # instead, which costs a second and blocks nothing clean. A body sent with
    # --input, or anything read from stdin, counts as a mutation too. Only
    # the values flags actually take are looked at, so an option's value (a
    # --template that reads as -fquery=...) never replaces the query.
    if [[ "$(lower "$api_endpoint")" == graphql ]]; then
      query_known=true
      for (( i = 0; i < ${#args[@]}; i++ )); do
        [[ "${role[i]}" == value || "${role[i]}" == attached ]] || continue
        case "${opt[i]}" in
          --input)
            query_known=false
            break
            ;;
          -f | -F | --field | --raw-field)
            [[ "${val[i]}" == query=* ]] || continue
            query=${val[i]#query=}
            if [[ "${opt[i]}" == -F || "${opt[i]}" == --field ]] && [[ "$query" == @* ]]; then
              if [[ "$query" == @- || ! -f "${query#@}" ]]; then
                query_known=false
                break
              fi
              query=$(cat "${query#@}")
            fi
            ;;
        esac
      done
      if $query_known && [[ -n "$query" ]] &&
        ! printf '%s\n' "$query" | grep -Eq '(^|[^A-Za-z0-9_])mutation([^A-Za-z0-9_]|$)'; then
        exec "$real_gh" "$@"
      fi
    fi
  fi
fi

resolve_destination
if [[ -z "$opaque" && "$destination" == private ]]; then exec "$real_gh" "$@"; fi

refuse_unseen_text

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
text="$work_dir/text"
: > "$text"

if [[ "$destination" == public ]]; then
  label="public repository $target"
else
  printf -v target '%s, ' "${publics[@]}"
  target=${target%, }
  label="a destination that could not be shown to be private (the public repositories are $target)"
fi

if [[ -z "$opaque" ]] && arity_known && ! $any_unsure; then collect_exact; else collect_any; fi
if implicit_stdin; then take_stdin; fi

if ! "$checkout/scripts/check-private-names.sh" --text "gh $group $action" < "$text"; then
  echo "gh: refused — nothing was posted to $label." >&2
  exit 1
fi

if [[ -n "$opaque" && "$destination" != private ]]; then
  refuse "$opaque runs code this guard cannot inspect, and nothing shows that it posts only to private repositories: it is aimed at $label."
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
