# Journal writer for the pinned codex-orchestrator contract; preserves prior bytes.
# Packaged by writeShellApplication, like codex-scope (strict mode, no shebang).
# One orchestrator owns a run; concurrent writers are not supported upstream.

usage() {
  echo "codex-journal: $*" >&2
  cat >&2 <<'USAGE'
usage: codex-journal <command> --run-dir DIR [flags]
  start     --run-id ID --repo ROOT --goal TEXT [--codex-version VERSION]
            [--plugin-ref REF] [--claude-version VERSION]
  task      --id ID --status pending|active|complete|blocked|failed
            [--goal TEXT] [--acceptance TEXT ...] [--file PATH ...]
            New tasks require --goal, --acceptance and --file.
  execution --agent NAME --execution ID --task ID --role ROLE --model MODEL
            --effort LEVEL --effort-reason TEXT [--service-tier TIER]
            --worktree ROOT --baseline-tree TREE
            --prompt PATH --events PATH --handoff PATH
  result    --agent NAME --execution ID --status complete|blocked|failed
            --summary TEXT [--changed-file PATH ...] [--caveat TEXT ...]
  verify    --id ID --task ID --criterion TEXT --method METHOD --check TEXT
            --result passed|failed|inconclusive|skipped --observation TEXT
            [--evidence PATH ...]
  close     --judgment passed|blocked --summary TEXT
            [--risk TEXT ...] [--follow-up TEXT ...]
Paths to run artifacts may be absolute or relative to DIR. Close appends terminal
updates for open tasks (complete for passed, blocked for blocked), preserves prior
records, validates before closure, stores that output, then validates again.
Each record is committed by atomic replacement. Only one writer may use a run
directory at a time. Identifiers and paths must not contain newlines.
USAGE
  exit 2
}

[[ $# -gt 0 ]] || usage "missing command"
command="$1"
shift
case "$command" in
  start) flags=" run-id repo goal codex-version plugin-ref claude-version " ;;
  task) flags=" id status goal acceptance file " ;;
  execution) flags=" agent execution task role model effort effort-reason service-tier worktree baseline-tree prompt events handoff " ;;
  result) flags=" agent execution status summary changed-file caveat " ;;
  verify) flags=" id task criterion method check result observation evidence " ;;
  close) flags=" judgment summary risk follow-up " ;;
  *) usage "unknown command: $command" ;;
esac

args='{}'
while (( $# )); do
  [[ "$1" == --* && $# -ge 2 && -n "$2" && "$2" != --* ]] || usage "expected --flag VALUE: $1"
  flag="${1#--}"
  [[ "$flag" == run-dir || "$flags" == *" $flag "* ]] || usage "unknown flag for $command: $1"
  case "$flag" in
    goal | acceptance | effort-reason | summary | caveat | criterion | check | observation | risk | follow-up) ;;
    *) [[ "$2" != *$'\n'* ]] || usage "newline in --$flag is not allowed" ;;
  esac
  key="${flag//-/_}"
  case "$flag" in
    file) key=files ;;
    changed-file) key=files_changed ;;
    caveat) key=caveats ;;
    risk) key=risks ;;
    follow-up) key=follow_ups ;;
  esac
  case "$flag" in
    acceptance | file | changed-file | caveat | evidence | risk | follow-up)
      args="$(jq -c --arg k "$key" --arg v "$2" '.[$k] = ((.[$k] // []) + [$v])' <<<"$args")"
      ;;
    *)
      jq -e --arg k "$key" 'has($k) | not' <<<"$args" >/dev/null || usage "duplicate flag: $1"
      args="$(jq -c --arg k "$key" --arg v "$2" '.[$k] = $v' <<<"$args")"
      ;;
  esac
  shift 2
done

need() {
  local key flag
  for key in "$@"; do
    flag="${key//_/-}"
    [[ "$key" != files ]] || flag="file"
    jq -e --arg k "$key" 'has($k)' <<<"$args" >/dev/null || usage "missing required flag: --$flag"
  done
}
value() { jq -r --arg k "$1" '.[$k] // empty' <<<"$args"; }
enum() {
  local actual option
  actual="$(value "$1")"
  for option in $2; do
    [[ "$actual" != "$option" ]] || return 0
  done
  usage "invalid --${1//_/-}: $actual (expected $2)"
}
root() {
  local path="$1" physical
  physical="$(cd -P "$path" && printf '%s/' "$PWD")"
  physical="${physical%/}"
  [[ "$physical" != *$'\n'* ]] || usage "newline in worktree path is not allowed"
  [[ "$(git -C "$path" rev-parse --show-toplevel)" == "$physical" ]] || usage "$path is not a worktree root"
  printf '%s' "$physical"
}
artifact() {
  if [[ "$1" == /* ]]; then printf '%s' "$1"; else printf '%s/%s' "$run_dir" "$1"; fi
}
check_final_line() {
  if [[ -s "$journal" ]]; then
    [[ "$(tail -c 1 "$journal" | wc -l)" -eq 1 ]] || usage "journal has an unterminated final line; prior records preserved"
    tail -n 1 "$journal" | jq -se 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 \
      || usage "journal final line must be one complete JSON object; prior records preserved"
  fi
}
pending_journal=''
cleanup() {
  if [[ -n "$pending_journal" ]]; then rm -f -- "$pending_journal"; fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
append() {
  local line
  line="$(jq -c --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '. + {recorded_at: $at}' <<<"$1")"
  check_final_line
  pending_journal="$run_dir/.journal.$$"
  if ! (umask 077; set -o noclobber; : >"$pending_journal"); then
    pending_journal=''
    usage "cannot exclusively create journal staging file"
  fi
  if [[ -e "$journal" ]]; then cat "$journal" >"$pending_journal"; fi
  printf '%s\n' "$line" >>"$pending_journal"
  mv -f -- "$pending_journal" "$journal"
  pending_journal=''
}

need run_dir
run_dir="$(value run_dir)"
path="$run_dir"
while [[ "$path" != / && "$path" != . ]]; do
  if [[ "$path" == */ ]]; then path="${path%/}"; continue; fi
  [[ ! -L "$path" ]] || usage "symlink in run directory path: $path"
  if [[ "$path" == */* ]]; then path="${path%/*}"; else path=.; fi
  [[ -n "$path" ]] || path=/
done
if [[ "$command" == start ]]; then
  need run_id repo goal
  repo="$(root "$(value repo)")"
  # Capture before creating the run directory, as required by the contract.
  head="$(git -C "$repo" rev-parse HEAD)"
  branch="$(git -C "$repo" symbolic-ref --quiet --short HEAD || true)"
  status="$(git -C "$repo" status --short --untracked-files=all | jq -Rsc 'split("\n") | map(select(length > 0))')"
  mkdir -p "$run_dir"
fi
[[ -d "$run_dir" ]] || usage "run directory does not exist: $run_dir"
run_dir="$(cd -P "$run_dir" && printf '%s/' "$PWD")"
run_dir="${run_dir%/}"
[[ "$run_dir" != *$'\n'* ]] || usage "newline in --run-dir is not allowed"
journal="$run_dir/journal.jsonl"
[[ ! -L "$journal" ]] || usage "journal must not be a symlink: $journal"
record="$(jq -c 'del(.run_dir)' <<<"$args")"
history='[]'
if [[ -e "$journal" ]]; then
  check_final_line
  history="$(jq -sc '.' "$journal")"
fi
if [[ "$command" == start ]]; then
  [[ ! -s "$journal" ]] || usage "journal already exists; start a successor run"
else
  jq -e 'length > 0 and .[0].type == "run_started" and all(.[]; .type != "run_closed")' <<<"$history" >/dev/null \
    || usage "run must be started and not closed"
fi

case "$command" in
  start)
    version="$(value codex_version)"
    if [[ -z "$version" ]] && command -v codex >/dev/null; then version="$(codex --version)"; fi
    record="$(jq -c --arg repo "$repo" --arg head "$head" --arg branch "$branch" --argjson status "$status" --arg version "$version" '
      . + {type: "run_started", repo: $repo, repo_head: $head, repo_status: $status}
      | if $branch != "" then .repo_branch = $branch else . end
      | if $version != "" then .codex_version = $version else . end' <<<"$record")"
    ;;
  task)
    need id status
    enum status "pending active complete blocked failed"
    previous="$(jq -c --arg id "$(value id)" '[.[] | select(.type == "task" and .id == $id)] | last // {}' <<<"$history")"
    if [[ "$previous" == '{}' ]]; then need goal acceptance files; fi
    record="$(jq -c --argjson previous "$previous" '$previous + . + {type: "task"} | del(.recorded_at)' <<<"$record")"
    ;;
  execution | verify)
    need task
    jq -e --arg task "$(value task)" 'any(.[]; .type == "task" and .id == $task)' <<<"$history" >/dev/null \
      || usage "unknown task: $(value task)"
    if [[ "$command" == execution ]]; then
      need agent execution role model effort effort_reason worktree baseline_tree prompt events handoff
      # Pinned upstream scripts/codex_orchestrator/role_config.py defines these.
      # Its orchestration contract deliberately leaves journal roles open.
      enum effort "low medium high xhigh max ultra"
      if jq -e 'has("service_tier")' <<<"$args" >/dev/null; then enum service_tier "default fast"; fi
      worktree="$(root "$(value worktree)")"
      git -C "$worktree" cat-file -e "$(value baseline_tree)^{tree}"
      jq -e --arg a "$(value agent)" --arg e "$(value execution)" \
        'any(.[]; .type == "execution" and .agent == $a and .execution == $e) | not' <<<"$history" >/dev/null \
        || usage "duplicate execution; start a successor run"
      head="$(git -C "$worktree" rev-parse HEAD)"
      branch="$(git -C "$worktree" symbolic-ref --quiet --short HEAD || true)"
      record="$(jq -c --arg w "$worktree" --arg h "$head" --arg b "$branch" '
        . + {type: "execution", provider: "codex", mode: "headless", event_source: "exec", worktree: $w, head: $h}
        | if $b != "" then .branch = $b else . end' <<<"$record")"
    else
      need id criterion method check result observation
      enum result "passed failed inconclusive skipped"
      jq -e --arg id "$(value id)" 'any(.[]; .type == "verification" and .id == $id) | not' <<<"$history" >/dev/null \
        || usage "duplicate verification id; start a successor run"
      record="$(jq -c '. + {type: "verification", evidence: (.evidence // [])}' <<<"$record")"
    fi
    ;;
  result)
    need agent execution status summary
    enum status "complete blocked failed"
    execution="$(jq -c --arg a "$(value agent)" --arg e "$(value execution)" '
      [.[] | select(.type == "execution" and .agent == $a and .execution == $e)] | last // empty' <<<"$history")"
    [[ -n "$execution" ]] || usage "unknown execution"
    jq -e --arg a "$(value agent)" --arg e "$(value execution)" \
      'any(.[]; .type == "execution_result" and .agent == $a and .execution == $e) | not' <<<"$history" >/dev/null \
      || usage "duplicate execution_result; start a successor run"
    events="$(artifact "$(jq -r '.events' <<<"$execution")")"
    session='[]'
    if [[ -f "$events" ]]; then
      # read refuses an unterminated EOF chunk, which upstream's runner preserves.
      while IFS= read -r event; do
        if jq -e '.type == "thread.started"' <<<"$event" >/dev/null; then
          session="$(jq -c '[.thread_id | select(type == "string" and length > 0)]' <<<"$event")"
          break
        fi
      done <"$events"
    fi
    if [[ "$session" == '[]' ]]; then echo "codex-journal: session id unavailable in $events" >&2; fi
    if [[ "$(value status)" == complete ]]; then
      [[ -s "$(artifact "$(jq -r '.handoff' <<<"$execution")")" ]] || usage "complete execution needs a nonempty handoff"
    fi
    record="$(jq -c --argjson x "$execution" --argjson session "$session" '
      . + {type: "execution_result", task: $x.task, handoff: $x.handoff,
           files_changed: (.files_changed // []), caveats: (.caveats // [])}
      | if ($session | length) > 0 then .session_id = $session[0] else . end' <<<"$record")"
    ;;
  close)
    need judgment summary
    enum judgment "passed blocked"
    tools="${BASH_SOURCE[0]%/*}/../scripts/codex_orch_tools.py"
    [[ -f "$tools" ]] || usage "missing upstream validator: $tools"
    terminal=blocked
    if [[ "$(value judgment)" == passed ]]; then terminal=complete; fi
    updates="$(jq -c --arg status "$terminal" '
      [.[] | select(.type == "task")] | group_by(.id) | map(last)
      | .[] | select(.status != "complete" and .status != "blocked" and .status != "failed")
      | .status = $status | del(.recorded_at)' <<<"$history")"
    while IFS= read -r update; do
      [[ -z "$update" ]] || append "$update"
    done <<<"$updates"
    if ! validation="$(python3 "$tools" validate "$run_dir")"; then
      printf '%s\n' "$validation" >&2
      echo "codex-journal: validation failed; run remains open, prior records preserved" >&2
      exit 1
    fi
    record="$(jq -c --argjson validation "$validation" '
      . + {type: "run_closed", validation: $validation, risks: (.risks // []), follow_ups: (.follow_ups // [])}' <<<"$record")"
    append "$record"
    python3 "$tools" validate "$run_dir"
    exit
    ;;
esac
append "$record"
