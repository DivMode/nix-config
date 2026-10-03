# PreToolUse hook for Codex jobs Claude delegates through /codex-orchestrator:delegate.
# Packaged by modules/home/ai with writeShellApplication (strict mode, shellcheck, jq on PATH),
# so this file has no shebang.
#
# Delegated jobs run without a sandbox. This hook rejects committing, pushing, shipping, and
# deploying before the command runs. Those are Claude's job after review. It is passed inline
# on each job's command line (`-c hooks.PreToolUse=[...]` with --dangerously-bypass-hook-trust),
# so the user's own Codex sessions never load it and no file is written into the repository.
#
# The command is split into simple commands, and quotes, brackets, and backticks are dropped, so
# `git -C dir push`, `bash -c '...'`, `env X=1 git ...`, `$(...)`, and `/usr/bin/git` are all
# caught. This stops ordinary mistakes, not a determined bypass (an interpreter one-liner gets
# through). Verified 2026-10-03 in codex exec 0.159.2 with sandbox off: matching commands were
# rejected before running with the reason below; others ran.

deny() {
  jq -n --arg r "delegated Codex job: $1. Leave changes uncommitted; Claude commits and ships after review" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

input="$(cat)"
# Fail closed: a command this hook cannot read is not run.
if ! cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty | if type == "array" then join(" ") else . end')"; then
  deny "the guard could not read this command"
fi
[[ -n "$cmd" ]] || exit 0

# tr pads the second set with its last character: each separator becomes a newline, and each quote,
# bracket, or backtick becomes a space.
segments="$(printf '%s\n' "$cmd" | tr ';&|' '\n' | tr "\"'\`(){}" ' ' | tr -s ' \t' ' ')"
while IFS= read -r seg; do
  seg=" $seg "
  # A text search for these words is not running them.
  [[ $seg =~ ^\ ([^\ ]*/)?(rg|grep)\  ]] && continue
  # Canary: a made-up command to prove the hook is loaded.
  [[ $seg =~ \ codex-guard-canary\  ]] && deny "canary"
  [[ $seg =~ \ ([^\ ]*/)?git(\ [^\ ]+)*\ (commit|push)\  ]] && deny "no git commit or push"
  [[ $seg =~ \ ([^\ ]*/)?just\ (pr|ship)\  ]] && deny "no just pr or just ship"
  [[ $seg =~ \ ([^\ ]*/)?gh\ (pr|api|release)\  ]] && deny "no GitHub pull request, API, or release commands"
  [[ $seg =~ \ ([^\ ]*/)?(sst|alchemy)\ (deploy|remove|destroy)\  ]] && deny "no deploys"
  [[ $seg =~ \ ([^\ ]*/)?pulumi\ (up|destroy)\  ]] && deny "no deploys"
  [[ $seg =~ \ ([^\ ]*/)?wrangler\ deploy\  ]] && deny "no deploys"
  [[ $seg =~ \ ([^\ ]*/)?kubectl(\ [^\ ]+)*\ (apply|delete|patch)\  ]] && deny "no cluster changes"
done <<<"$segments"
exit 0
