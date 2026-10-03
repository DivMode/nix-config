# PreToolUse hook for Codex jobs Claude delegates through /codex-orchestrator:delegate.
# Packaged by modules/home/ai with writeShellApplication (strict mode, shellcheck, jq on PATH),
# so this file has no shebang.
#
# Delegated jobs run without a sandbox. This hook rejects committing, pushing, shipping, and
# deploying before the command runs. Those are Claude's job after review. It is passed inline
# on each job's command line (`-c hooks.PreToolUse=[...]` with --dangerously-bypass-hook-trust),
# so the user's own Codex sessions never load it and no file is written into the repository.
#
# Each command is split into simple commands. Quotes, brackets, backticks, and redirections become
# spaces, so `bash -c '...'`, `$(...)`, `env X=1 ...`, and `cmd>/dev/null` expose their words. For
# each known tool the hook then reads the real subcommand, skipping options and their values.
# `git stash push`, `git log --grep push`, and `gh pr view` stay allowed, while `git -C dir push`
# and `just --justfile f ship` are refused. A segment whose command is `rg` or `grep` is a text
# search and is skipped. Known limits: a mention such as `echo "git push"` is refused (harmless),
# and an interpreter one-liner or a script that runs these internally gets through. This guards
# against mistakes, not a determined bypass.

deny() {
  jq -n --arg r "delegated Codex job: $1. Leave changes uncommitted; Claude commits and ships after review" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

# Print the first argument at or after index $1 that is not an option, skipping the values of
# the options named in $2 (a space-separated list). Reads the global array `w`.
subcommand() {
  local i="$1" valued=" $2 "
  while ((i < ${#w[@]})); do
    case "${w[i]}" in
      --*=*) ;;
      -*)
        if [[ $valued == *" ${w[i]} "* ]]; then i=$((i + 1)); fi
        ;;
      *)
        printf '%s' "${w[i]}"
        return
        ;;
    esac
    i=$((i + 1))
  done
}

input="$(cat)"
# Fail closed: a command this hook cannot read is not run.
if ! cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty | if type == "array" then join(" ") else . end')"; then
  deny "the guard could not read this command"
fi
[[ -n "$cmd" ]] || exit 0

segments="$(printf '%s\n' "$cmd" | tr ';&|' '\n' | tr "\"'\`(){}<>" ' ')"
while IFS= read -r seg; do
  read -ra w <<<"$seg"
  ((${#w[@]})) || continue
  case "${w[0]##*/}" in rg | grep) continue ;; esac

  for ((n = 0; n < ${#w[@]}; n++)); do
    tool="${w[n]##*/}"
    case "$tool" in
      codex-guard-canary) deny "canary" ;;
      git)
        case "$(subcommand $((n + 1)) "-C -c --git-dir --work-tree --namespace --config-env")" in
          commit | push | merge | rebase | cherry-pick | revert | am | commit-tree | update-ref)
            deny "no git commits or pushes"
            ;;
        esac
        ;;
      just)
        case "$(subcommand $((n + 1)) "-f --justfile -d --working-directory --set --shell --dotenv-path --dotenv-filename --color")" in
          pr | ship) deny "no just pr or just ship" ;;
        esac
        ;;
      gh)
        group="$(subcommand $((n + 1)) "-R --repo")"
        case "$group" in
          pr | release)
            for ((k = n + 1; k < ${#w[@]}; k++)); do [[ ${w[k]} == "$group" ]] && break; done
            case "$group/$(subcommand $((k + 1)) "-R --repo")" in
              pr/create | pr/merge | pr/close | pr/reopen | pr/edit | pr/comment | pr/review | pr/ready | \
                release/create | release/delete | release/edit | release/upload)
                deny "no GitHub pull request or release writes"
                ;;
            esac
            ;;
          api)
            for ((k = n + 1; k < ${#w[@]}; k++)); do
              case "${w[k]}" in
                -f | -F | --field | --raw-field | --input) deny "no GitHub API writes" ;;
                -X | --method) [[ ${w[k + 1]:-GET} == [Gg][Ee][Tt] ]] || deny "no GitHub API writes" ;;
                --method=*) [[ ${w[k]#--method=} == [Gg][Ee][Tt] ]] || deny "no GitHub API writes" ;;
              esac
            done
            ;;
        esac
        ;;
      sst | alchemy)
        case "$(subcommand $((n + 1)) "--stage")" in deploy | remove | destroy) deny "no deploys" ;; esac
        ;;
      pulumi)
        case "$(subcommand $((n + 1)) "-s --stack -C --cwd")" in up | destroy) deny "no deploys" ;; esac
        ;;
      wrangler)
        case "$(subcommand $((n + 1)) "-c --config -e --env")" in deploy | publish) deny "no deploys" ;; esac
        ;;
      kubectl)
        case "$(subcommand $((n + 1)) "-n --namespace --context --kubeconfig --cluster --user -s --server")" in
          apply | delete | patch | edit | replace | scale | create) deny "no cluster changes" ;;
        esac
        ;;
      helm)
        case "$(subcommand $((n + 1)) "-n --namespace --kube-context --kubeconfig")" in
          install | upgrade | uninstall | rollback) deny "no cluster changes" ;;
        esac
        ;;
      flux)
        case "$(subcommand $((n + 1)) "-n --namespace --context --kubeconfig")" in
          reconcile | suspend | resume) deny "no cluster changes" ;;
        esac
        ;;
    esac
  done
done <<<"$segments"
exit 0
