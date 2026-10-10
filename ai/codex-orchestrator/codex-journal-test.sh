#!/usr/bin/env bash
# Exercise the real helper and pinned validator; retain the sample and diagnostics.
set -euo pipefail
[[ $# -eq 4 ]] || { echo "usage: $0 HELPER UPSTREAM REPO OUTPUT" >&2; exit 2; }
helper="$1"
upstream="$2"
repo="$3"
output="$4"
[[ ! -e "$output" ]] || { echo "test output already exists: $output" >&2; exit 2; }
mkdir -p "$output/plugin/local"
cp "$helper" "$output/plugin/local/codex-journal"
chmod +x "$output/plugin/local/codex-journal"
ln -s "$upstream/scripts" "$output/plugin/scripts"
helper="$output/plugin/local/codex-journal"
run="$output/sample-run"
invoke() { "$helper" "$1" --run-dir "$run" "${@:2}"; }
fail() { echo "codex-journal test: $*" >&2; exit 1; }

expected_status="$(git -C "$repo" status --short --untracked-files=all | jq -Rsc 'split("\n") | map(select(length > 0))')"
invoke start --run-id example-run --repo "$repo" --goal 'Verify the journal writer' \
  --codex-version example-version --plugin-ref v0.5.1
invoke task --id task-01 --status active --goal 'Write valid records' \
  --acceptance 'Upstream validates the run' --file example.txt
invoke task --id task-02 --status pending --goal 'Record a separate task' \
  --acceptance 'Explicit completion is preserved' --file other.txt
invoke task --id task-02 --status active
invoke task --id task-02 --status complete
exec_dir="$run/codex-impl-01/execution-01"
mkdir -p "$exec_dir"
printf '%s\n' 'Example assignment' >"$exec_dir/prompt.md"
invoke execution --agent codex-impl-01 --execution execution-01 --task task-01 \
  --role implementation --model example-model --effort high --effort-reason 'Bounded implementation' \
  --service-tier fast --worktree "$repo" --baseline-tree "$(git -C "$repo" rev-parse 'HEAD^{tree}')" \
  --prompt "$exec_dir/prompt.md" --events "$exec_dir/events.jsonl" --handoff "$exec_dir/handoff.md"
printf '%s\n' '{"type":"thread.started","thread_id":"example-session"}' '{"type":"turn.completed"}' >"$exec_dir/events.jsonl"
printf '%s\n' 'Example handoff' >"$exec_dir/handoff.md"
invoke result --agent codex-impl-01 --execution execution-01 --status complete \
  --summary 'Recorded the implementation' --changed-file example.txt --caveat 'Example caveat'

# Usage errors must refuse the write, including the enum that caused the incident.
cp "$run/journal.jsonl" "$output/before-errors.jsonl"
if invoke verify --id check-missing --task task-01 --criterion 'Required flag' \
  --method command --check true --result passed >"$output/missing-flag.txt" 2>&1; then
  fail 'missing --observation accepted'
else
  [[ $? -eq 2 ]] || fail 'missing flag did not return usage exit 2'
fi
grep -qF 'missing required flag: --observation' "$output/missing-flag.txt" || fail 'missing flag diagnostic absent'
if invoke verify --id check-bad --task task-01 --criterion 'Result enum' \
  --method command --check true --result pass --observation 'Example observation' >"$output/bad-enum.txt" 2>&1; then
  fail 'bad verification enum accepted'
else
  [[ $? -eq 2 ]] || fail 'bad enum did not return usage exit 2'
fi
cmp "$output/before-errors.jsonl" "$run/journal.jsonl"
echo 'PASS: missing required flag and bad enum refused without appending'

invoke verify --id check-01 --task task-01 --criterion 'Example criterion' --method command \
  --check 'example-check' --result passed --observation 'Example check passed' --evidence "$exec_dir/handoff.md"
cp "$run/journal.jsonl" "$output/before-close.jsonl"
invoke close --judgment passed --summary 'All example criteria verified' \
  --risk 'Example residual risk' --follow-up 'Example follow-up' >"$output/close-validation.json"
python3 "$upstream/scripts/codex_orch_tools.py" validate "$run" >"$output/validation.json"
jq -e '.ok and .issues == []' "$output/validation.json" >/dev/null
head -n "$(wc -l <"$output/before-close.jsonl")" "$run/journal.jsonl" >"$output/preserved-prefix.jsonl"
cmp "$output/before-close.jsonl" "$output/preserved-prefix.jsonl"
jq -se --arg repo "$(cd "$repo" && pwd -P)" --arg head "$(git -C "$repo" rev-parse HEAD)" --argjson status "$expected_status" '
  all(.[]; .recorded_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  and (.[0] | .repo == $repo and .repo_head == $head and .repo_status == $status and .codex_version == "example-version")
  and (map(select(.type == "execution"))[0] | .head == $head and .service_tier == "fast" and .effort_reason == "Bounded implementation")
  and (map(select(.type == "execution_result"))[0] | .session_id == "example-session" and .task == "task-01")
  and (map(select(.type == "task" and .id == "task-01")) | last | .status == "complete" and .files == ["example.txt"])
  and (.[-1] | .type == "run_closed" and .judgment == "passed" and .validation.ok and .risks == ["Example residual risk"] and .follow_ups == ["Example follow-up"])
' "$run/journal.jsonl" >/dev/null
echo 'PASS: complete run validates; baseline, session id, terminal tasks and closure preserved'

# A known-bad copy proves upstream sees the exact enum failure, without altering the run.
mkdir "$output/bad-run"
jq -c 'if .type == "verification" then .result = "pass" else . end' \
  "$run/journal.jsonl" >"$output/bad-run/journal.jsonl"
if python3 "$upstream/scripts/codex_orch_tools.py" validate "$output/bad-run" >"$output/bad-validation.json"; then
  fail 'upstream accepted the known-bad record'
fi
jq -e '.ok == false and any(.issues[]; contains("verification result is not recognized: pass"))' \
  "$output/bad-validation.json" >/dev/null
cat "$output/bad-validation.json"
echo 'PASS: known-bad verification record fails upstream validation'

# Closure must fail loudly for missing execution artifacts and leave history intact.
run="$output/incomplete-run"
invoke start --run-id incomplete-run --repo "$repo" --goal 'Verify failed closure' --codex-version example-version
invoke task --id task-01 --status active --goal 'Missing artifacts' --acceptance 'Closure fails' --file example.txt
invoke execution --agent codex-impl-01 --execution execution-01 --task task-01 \
  --role implementation --model example-model --effort high --effort-reason 'Example reason' \
  --worktree "$repo" --baseline-tree "$(git -C "$repo" rev-parse 'HEAD^{tree}')" \
  --prompt "$exec_dir/prompt.md" --events missing-events.jsonl --handoff missing-handoff.md
invoke result --agent codex-impl-01 --execution execution-01 --status blocked --summary 'No session started'
if invoke close --judgment blocked --summary 'Missing event stream' >"$output/failed-close.txt" 2>&1; then
  fail 'closure accepted missing event stream'
fi
grep -qF 'referenced events file does not exist' "$output/failed-close.txt" || fail 'upstream issue not reported'
jq -se 'all(.[]; .type != "run_closed") and (.[-1].type == "task" and .[-1].status == "blocked")' "$run/journal.jsonl" >/dev/null
echo 'PASS: failed validation reports the issue and leaves the run open'

# Keep the four regression groups independent so all before-fix failures are visible.
regression_failures=0
regression_fail() {
  echo "FAIL: $*" >&2
  regression_failures=$((regression_failures + 1))
}
fixture() {
  run="$output/$1"
  invoke start --run-id example-run --repo "$repo" --goal 'Regression fixture' --codex-version example-version
  invoke task --id task-01 --status active --goal 'Regression task' --acceptance 'Required behavior' --file example.txt
}
baseline_tree="$(git -C "$repo" rev-parse 'HEAD^{tree}')"
execution_flags=(--agent example-agent --task task-01 --role implementation --model example-model
  --effort-reason 'Regression check' --worktree "$repo" --baseline-tree "$baseline_tree"
  --prompt prompt.md --handoff handoff.md)

# 1: A resource-limit failure must preserve exact bytes and clean up its staging file.
before_failures=$regression_failures
fixture atomic-run
cp "$run/journal.jsonl" "$output/before-atomic.jsonl"
long_goal="$(jq -nr '"x" * 20000')"
if (ulimit -f 4; invoke task --id oversized --status active --goal "$long_goal" \
  --acceptance 'Preserve journal on write failure' --file example.txt) >"$output/limited-write.txt" 2>&1; then
  regression_fail 'atomic: limited write unexpectedly succeeded'
fi
cmp -s "$output/before-atomic.jsonl" "$run/journal.jsonl" || regression_fail 'atomic: failed write changed journal bytes'
[[ "$(find "$run" -mindepth 1 -maxdepth 1 -type f | wc -l)" -eq 1 ]] \
  || regression_fail 'atomic: failed write left a temporary file'
cp "$output/before-atomic.jsonl" "$run/journal.jsonl"
for final in '{"type":' '{"type":' 'true' '{} {}' ''; do
  cp "$output/before-atomic.jsonl" "$run/journal.jsonl"
  if [[ "$final" == '{"type":' && ! -e "$output/unterminated-tested" ]]; then
    printf '%s' "$final" >>"$run/journal.jsonl"
    touch "$output/unterminated-tested"
  else
    printf '%s\n' "$final" >>"$run/journal.jsonl"
  fi
  cp "$run/journal.jsonl" "$output/before-incomplete.jsonl"
  if invoke task --id task-01 --status complete >"$output/incomplete-line.txt" 2>&1; then
    regression_fail 'atomic: incomplete or non-object final line accepted'
  else
    [[ $? -eq 2 ]] || regression_fail 'atomic: incomplete final line did not return usage exit 2'
  fi
  grep -qF 'final line' "$output/incomplete-line.txt" || regression_fail 'atomic: incomplete final line diagnostic absent'
  cmp -s "$output/before-incomplete.jsonl" "$run/journal.jsonl" || regression_fail 'atomic: refused append changed journal bytes'
done
cp "$output/before-atomic.jsonl" "$run/journal.jsonl"
text=$'Quoted "goal"\nwith a trailing newline\n'
invoke task --id task-01 --status complete --goal "$text"
head -n "$(wc -l <"$output/before-atomic.jsonl")" "$run/journal.jsonl" >"$output/atomic-prefix.jsonl"
cmp "$output/before-atomic.jsonl" "$output/atomic-prefix.jsonl"
jq -se --arg goal "$text" '.[-1].goal == $goal' "$run/journal.jsonl" >/dev/null
[[ $regression_failures -ne $before_failures ]] || echo 'PASS: atomic replacement preserves bytes on failure and refuses incomplete final records'

# 2: Interrupted streams and missing session IDs must still permit failed/blocked results.
before_failures=$regression_failures
fixture truncated-events-run
for status in failed blocked; do
  events="$status-events.jsonl"
  invoke execution --execution "$status-session" "${execution_flags[@]}" --effort high --events "$events"
  printf '%s\n' '{"type":"turn.started"}' '{"type":"thread.started","thread_id":"first-session"}' \
    '{"type":"thread.started","thread_id":"later-session"}' >"$run/$events"
  printf '%s' '{"type":"turn.' >>"$run/$events"
  cp "$run/$events" "$output/$events"
  if invoke result --agent example-agent --execution "$status-session" --status "$status" \
    --summary 'Interrupted execution' >"$output/$status-result.txt" 2>&1; then
    jq -se --arg status "$status" '.[-1].type == "execution_result" and .[-1].status == $status
      and .[-1].session_id == "first-session"' "$run/journal.jsonl" >/dev/null \
      || regression_fail 'events: first thread.started session not recorded'
  else
    regression_fail 'events: truncated stream prevented terminal result'
  fi
  cmp "$output/$events" "$run/$events"
  invoke execution --execution "$status-no-session" "${execution_flags[@]}" --effort high --events "$status-missing.jsonl"
  printf '%s' '{"type":"thread.' >"$run/$status-missing.jsonl"
  if invoke result --agent example-agent --execution "$status-no-session" --status "$status" \
    --summary 'No session available' >"$output/$status-no-session.txt" 2>&1; then
    jq -se --arg status "$status" '.[-1].type == "execution_result" and .[-1].status == $status
      and (.[-1] | has("session_id") | not)' "$run/journal.jsonl" >/dev/null \
      || regression_fail 'events: missing session result not recorded'
    grep -qF 'session id unavailable' "$output/$status-no-session.txt" || regression_fail 'events: missing session diagnostic absent'
  else
    regression_fail 'events: missing session prevented terminal result'
  fi
done
[[ $regression_failures -ne $before_failures ]] || echo 'PASS: truncated events use the first session; missing sessions are reported without blocking failure records'

# 3: Read the allowed values from pinned upstream, never from a second local list.
before_failures=$regression_failures
fixture execution-enums-run
python3 - "$upstream" >"$output/upstream-enums.txt" <<'PY'
import ast
from pathlib import Path
import sys
tree = ast.parse((Path(sys.argv[1]) / "scripts/codex_orchestrator/role_config.py").read_text())
fields = {"REASONING_EFFORTS": "effort", "SPEEDS": "service-tier"}
found = set()
for node in tree.body:
    if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
        name = node.targets[0].id
        if name in fields:
            values = ast.literal_eval(node.value)
            assert values and all(isinstance(value, str) for value in values)
            print(fields[name], *values)
            found.add(name)
assert found == fields.keys(), "pinned upstream execution enums missing"
PY
while read -r field choices; do
  for choice in $choices; do
    effort=high tier=default
    if [[ "$field" == effort ]]; then effort="$choice"; else tier="$choice"; fi
    invoke execution --execution "enum-$field-$choice" "${execution_flags[@]}" --events events.jsonl \
      --effort "$effort" --service-tier "$tier"
    jq -se --arg field "${field//-/_}" --arg choice "$choice" '.[-1][$field] == $choice' "$run/journal.jsonl" >/dev/null
  done
  cp "$run/journal.jsonl" "$output/before-execution-enum.jsonl"
  bad=(--effort high --service-tier default)
  if [[ "$field" == effort ]]; then bad[1]=banana; else bad[3]=slow; fi
  if invoke execution --execution "bad-$field" "${execution_flags[@]}" --events events.jsonl \
    "${bad[@]}" >"$output/bad-$field.txt" 2>&1; then
    regression_fail "enums: invalid $field accepted"
  else
    [[ $? -eq 2 ]] || regression_fail "enums: invalid $field did not return usage exit 2"
  fi
  grep -qF "invalid --$field:" "$output/bad-$field.txt" || regression_fail "enums: $field diagnostic absent"
  cmp -s "$output/before-execution-enum.jsonl" "$run/journal.jsonl" || regression_fail "enums: refused $field changed journal"
done <"$output/upstream-enums.txt"
[[ $regression_failures -ne $before_failures ]] || echo 'PASS: all pinned upstream efforts and tiers accepted; invalid values refused'

# 4: Identifiers and paths must be rejected before command substitution can trim them.
before_failures=$regression_failures
fixture newline-run
cp "$run/journal.jsonl" "$output/before-newline.jsonl"
for field in id file events prompt run-dir; do
  case "$field" in
    id) argv=(task --run-dir "$run" --id $'newline-task\n' --status active --goal 'New task' --acceptance 'Refuse newline' --file example.txt) ;;
    file) argv=(task --run-dir "$run" --id task-01 --status complete --file $'example\n.txt') ;;
    events) argv=(execution --run-dir "$run" --execution newline-events "${execution_flags[@]}" --effort high --events $'events\n') ;;
    prompt) argv=(execution --run-dir "$run" --execution newline-prompt "${execution_flags[@]}" --effort high --events events.jsonl)
      for ((i=0; i<${#argv[@]}; i++)); do [[ "${argv[i]}" != --prompt ]] || argv[i+1]=$'prompt\n.md'; done ;;
    run-dir) argv=(task --run-dir "$run"$'\n' --id task-01 --status complete) ;;
  esac
  if "$helper" "${argv[@]}" >"$output/newline-$field.txt" 2>&1; then
    regression_fail "newlines: $field containing newline accepted"
  else
    [[ $? -eq 2 ]] || regression_fail "newlines: $field did not return usage exit 2"
  fi
  grep -qF "newline in --$field" "$output/newline-$field.txt" || regression_fail "newlines: $field diagnostic absent"
  cmp -s "$output/before-newline.jsonl" "$run/journal.jsonl" || regression_fail "newlines: $field changed journal"
  cp "$output/before-newline.jsonl" "$run/journal.jsonl"
done
[[ $regression_failures -ne $before_failures ]] || echo 'PASS: identifiers and paths containing embedded or trailing newlines refused'
# Signals at allocation must remove staging files even before a pathname is returned.
before_failures=$regression_failures
fixture allocation-signal-run
if python3 - "$helper" "$run" "$output" <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

helper, run, output = map(Path, sys.argv[1:])
before = (run / "journal.jsonl").read_bytes()
hook = output / "allocation-hook.sh"
# The old allocator pauses before delivering its name; the replacement pauses
# at the first copy after exclusive creation. Both use real filesystem writes.
hook.write_text('''
mktemp() {
  local made
  made="$(command mktemp "$@")"
  printf '%s\\n' "$made" >"$ALLOCATION_MARKER"
  sleep 10
  printf '%s\\n' "$made"
}
cat() {
  if [[ "$1" == "$ALLOCATION_JOURNAL" ]]; then
    printf '%s\\n' ready >"$ALLOCATION_MARKER"
    sleep 10
  fi
  command cat "$@"
}
''')
failures = 0
for name, expected in [("SIGHUP", 129), ("SIGINT", 130), ("SIGTERM", 143)]:
    marker = output / (name + "-allocation-ready")
    env = dict(os.environ, BASH_ENV=str(hook), ALLOCATION_MARKER=str(marker),
               ALLOCATION_JOURNAL=str(run / "journal.jsonl"))
    proc = subprocess.Popen([str(helper), "task", "--run-dir", str(run),
                             "--id", "task-01", "--status", "complete"],
                            env=env, start_new_session=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    deadline = time.monotonic() + 5
    while not marker.exists() and proc.poll() is None and time.monotonic() < deadline:
        time.sleep(0.02)
    ready = marker.exists()
    if proc.poll() is None:
        os.killpg(proc.pid, getattr(signal, name))
    diagnostics, _ = proc.communicate(timeout=15)
    (output / (name + "-allocation.txt")).write_bytes(diagnostics)
    leftovers = list(run.glob(".journal.*"))
    unchanged = (run / "journal.jsonl").read_bytes() == before
    print(f"allocation {name}: ready={ready} exit={proc.returncode} "
          f"unchanged={unchanged} leftovers={len(leftovers)}", flush=True)
    if not ready or proc.returncode != expected or not unchanged or leftovers:
        failures += 1
sys.exit(bool(failures))
PY
then
  echo 'PASS: allocation interrupted by HUP/INT/TERM preserves journal bytes and removes staging files'
else
  regression_fail 'allocation: interrupted creation leaked staging files or changed journal'
fi

# Refuse live/dangling journal links and linked run paths without writing anything.
before_failures=$regression_failures
for kind in live dangling run parent; do
  fixture "symlink-$kind-run"
  original_run="$run"
  cp "$run/journal.jsonl" "$output/before-symlink-$kind.jsonl"
  case "$kind" in
    live | dangling)
      mv "$run/journal.jsonl" "$output/symlink-$kind-target.jsonl"
      target="$output/symlink-$kind-target.jsonl"
      [[ "$kind" != dangling ]] || target="$output/missing-journal.jsonl"
      ln -s "$target" "$run/journal.jsonl"
      link="$run/journal.jsonl"
      ;;
    run)
      link="$output/linked-run"
      ln -s "$run" "$link"
      run="$link"
      ;;
    parent)
      link="$output/linked-parent"
      ln -s "$output" "$link"
      run="$link/${run##*/}"
      ;;
  esac
  if invoke task --id task-01 --status complete >"$output/symlink-$kind.txt" 2>&1; then
    regression_fail "symlink: $kind accepted"
  else
    [[ $? -eq 2 ]] || regression_fail "symlink: $kind did not return usage exit 2"
  fi
  grep -qF 'symlink' "$output/symlink-$kind.txt" || regression_fail "symlink: $kind diagnostic absent"
  [[ -L "$link" ]] || regression_fail "symlink: $kind link replaced"
  if [[ "$kind" == live || "$kind" == dangling ]]; then
    cmp -s "$output/before-symlink-$kind.jsonl" "$output/symlink-$kind-target.jsonl" \
      || regression_fail "symlink: $kind target changed"
    [[ "$(readlink "$link")" == "$target" ]] || regression_fail "symlink: $kind link target changed"
    [[ "$kind" != dangling || ! -e "$target" ]] || regression_fail 'symlink: dangling target created'
  else
    cmp -s "$output/before-symlink-$kind.jsonl" "$original_run/journal.jsonl" \
      || regression_fail "symlink: $kind journal changed"
  fi
  [[ -z "$(find "$original_run" -name '.journal.*' -print)" ]] || regression_fail "symlink: $kind left staging files"
done
[[ $regression_failures -ne $before_failures ]] || echo 'PASS: symlinked journals and run paths refused without writes'
[[ $regression_failures -eq 0 ]] || fail "$regression_failures regression assertions failed"
