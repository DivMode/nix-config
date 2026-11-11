# Tests for kill-guard.sh. Run as:
#   <shell> kill-guard-test.sh <absolute path to kill-guard.sh> [NAMES]
# where <shell> is each shell the guard must work in (bash 5, bash 3.2, zsh)
# and NAMES, when given, is the command guard's list of interface agents,
# sorted and joined by single spaces, which the guard's own list must equal.
#
# Safety of the test itself. A real signal goes only to a process this test
# started, even if the guard under test is broken:
#   - a target that must never be signalled (-1, a group found in the process
#     table) is only ever given to a VERDICT function, which sends nothing;
#   - the real `kill` is called only with processes and groups started below,
#     and only after checking that `kill` is the guard's function;
#   - the real `pkill` and `killall` are called only with a name no process
#     has.

guard="$1"
expected_ui_agents="${2-}"
failures=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

allowed() {
  if ! __agent_kill_guard_verdict "$@" 2>/dev/null; then fail "should be allowed: kill $*"; fi
}

refused() {
  if __agent_kill_guard_verdict "$@" 2>/dev/null; then fail "should be refused: kill $*"; fi
}

killall_allowed() {
  if ! __agent_kill_guard_killall_verdict "$@" 2>/dev/null; then fail "should be allowed: killall $*"; fi
}

killall_refused() {
  if __agent_kill_guard_killall_verdict "$@" 2>/dev/null; then fail "should be refused: killall $*"; fi
}

is_function() {
  typeset -f "$1" >/dev/null 2>&1
}

# One field of one process, digits only; empty when the process is gone.
field() {
  __agent_kill_guard_ps -o "$1=" -p "$2" | tr -cd '0-9'
}

alive() {
  builtin kill -0 "$1" 2>/dev/null
}

# Waits until process $1 leads its own group (and, with $2, has that parent).
leads_own_group() {
  tries=0
  while [ "$tries" -lt 50 ]; do
    if [ "$(field pgid "$1")" = "$1" ] && { [ -z "${2-}" ] || [ "$(field ppid "$1")" = "$2" ]; }; then
      return 0
    fi
    tries=$((tries + 1))
    /bin/sleep 0.1
  done
  return 1
}

case "$guard" in
  /*) ;;
  *)
    echo "usage: <shell> kill-guard-test.sh <absolute path to kill-guard.sh> [NAMES]" >&2
    exit 2
    ;;
esac

# 1. Without the marker the file defines nothing. A shell an agent started
# has already loaded the guard, so drop that copy first.
unset AGENT_KILL_GUARD
unset -f kill pkill killall __agent_kill_guard_verdict __agent_kill_guard_killall_verdict __agent_kill_guard_owned __agent_kill_guard_ps 2>/dev/null
. "$guard"
for name in kill pkill killall __agent_kill_guard_verdict __agent_kill_guard_killall_verdict __agent_kill_guard_owned __agent_kill_guard_ps; do
  if is_function "$name"; then fail "$name defined without AGENT_KILL_GUARD"; fi
done

# 2. With the marker it defines everything and prints nothing: it is sourced
# ahead of every script an agent runs.
AGENT_KILL_GUARD=1
output="$(. "$guard" 2>&1)"
if [ -n "$output" ]; then fail "sourcing the guard printed: $output"; fi
. "$guard"
for name in kill pkill killall __agent_kill_guard_verdict __agent_kill_guard_killall_verdict __agent_kill_guard_owned __agent_kill_guard_ps; do
  if ! is_function "$name"; then
    echo "FAIL: $name not defined with AGENT_KILL_GUARD=1; stopping before any real call" >&2
    exit 1
  fi
done

# 3. Every spelling of "all my processes" is refused.
refused -- -1
refused -TERM -1
refused -TERM -- -1
refused -9 -1
refused -1 -1
refused -s TERM -1
refused -s TERM -- -1
refused -n 15 -1
refused -KILL -- -1 -2
refused 12345 -1
refused -TERM ' -1'
refused -TERM -- '-1 '
refused -TERM -- '- 1'
refused -- -0
refused -TERM -- -01
refused -TERM -- -abc
refused -TERM -- '-$group'
refused -TERM -- --1
refused -TERM -- -
refused --list -1
# Too large to be a process id or group: a shell that narrows the number to 32
# bits could turn it into -1.
refused -TERM -- -4294967297
refused -TERM 4294967295

# 4. A process group this shell did not start is refused. launchd's own
# children lead groups that no test shell can be an ancestor of, so look for a
# live group led by a child of process 1.
foreign="$(__agent_kill_guard_ps -axo pid=,ppid=,pgid= | awk '$2 == 1 && $1 == $3 && $1 > 1 { print $1; exit }')"
if [ -n "$foreign" ]; then
  refused -TERM -- "-$foreign"
  refused -KILL "-$foreign"
  refused -TERM 12345 "-$foreign"
  # The incident's shape: a long list where only some entries are foreign.
  refused -TERM -- "-$foreign" -1
else
  echo "note: no foreign process group found to test against" >&2
fi

# 5. Probes and listings deliver nothing, so they pass even for foreign targets.
allowed -0 -- -1
allowed -s 0 -- -1
allowed -n 0 -1
allowed -l
allowed -L
if [ -n "$foreign" ]; then allowed -0 -- "-$foreign"; fi

# 6. Single process ids, jobs and the caller's own group pass.
allowed 12345
allowed -TERM 12345
allowed -s TERM 12345 67890
allowed -9 12345
allowed -TERM ' 12345'
allowed -TERM %1
allowed 0
own="$(field pgid "$$")"
if [ -n "$own" ] && [ "$own" -gt 1 ]; then
  allowed -TERM -- "-$own"
else
  fail "could not read this shell's own process group"
fi

if [ "$failures" -gt 0 ]; then
  printf '%s failure(s) in the verdicts; stopping before any real call\n' "$failures" >&2
  exit 1
fi

# 7. A group this shell started is allowed, and the real function signals it,
# from a subshell and under `set -eu` as well. perl's setpgrp gives the child
# its own group whose leader is our child.
for mode in plain subshell strict; do
  /usr/bin/perl -e 'setpgrp(0, 0); exec "/bin/sleep", "60"' &
  child=$!
  if ! leads_own_group "$child" "$$"; then
    fail "test child did not become a group leader ($mode)"
    builtin kill "$child" 2>/dev/null
  else
    allowed -TERM -- "-$child"
    case "$mode" in
      plain) kill -TERM -- "-$child" ;;
      subshell) (kill -TERM -- "-$child") ;;
      strict) (
        set -eu
        kill -TERM -- "-$child"
      ) ;;
    esac || fail "kill of our own child group returned failure ($mode)"
  fi
  wait "$child" 2>/dev/null
  if alive "$child"; then fail "our own child group survived ($mode)"; fi
done

# 8. The real function on one child process id.
/bin/sleep 60 &
child=$!
kill "$child" || fail "kill of our own child returned failure"
wait "$child" 2>/dev/null
if alive "$child"; then fail "our own child survived"; fi

# 9. A refusal returns non-zero from the real function and signals nothing.
# The refused target is a group this test started and then orphaned: its
# leader's parent is process 1, so to the guard it is a foreign group, and
# were the guard broken the signal would reach only this test's own sleep.
orphan="$(/usr/bin/perl -e 'my $p = fork; die "fork failed" unless defined $p; if ($p) { print "$p\n"; exit 0 } setpgrp(0, 0); close STDOUT; exec "/bin/sleep", "60"')"
/bin/sleep 60 &
child=$!
case "$orphan" in
  '' | *[!0-9]*) fail "could not start the orphaned test group" ;;
  *)
    if ! leads_own_group "$orphan" 1; then
      fail "the orphaned test process did not become a group leader under process 1"
    else
      refused -TERM -- "-$orphan"
      if kill -TERM -- "-$orphan" 2>/dev/null; then fail "kill accepted a group this shell did not start"; fi
      if (
        set -eu
        kill -TERM -- "-$orphan"
      ) 2>/dev/null; then fail "kill accepted a group this shell did not start (strict)"; fi
      # The incident's shape: one refused entry refuses the whole list.
      if kill -TERM -- "$child" "-$orphan" 2>/dev/null; then fail "kill accepted a list containing a foreign group"; fi
      message="$(kill -TERM -- "-$orphan" 2>&1)"
      case "$message" in
        "kill guard: refused"*) ;;
        *) fail "the refusal did not say why: $message" ;;
      esac
      if ! alive "$orphan"; then fail "a refused kill still signalled the foreign group"; fi
      if ! alive "$child"; then fail "a refused kill still signalled a listed process"; fi
    fi
    builtin kill "$orphan" 2>/dev/null
    ;;
esac
builtin kill "$child" 2>/dev/null
wait "$child" 2>/dev/null

# 10. Pattern-based terminators. Every decision is checked through the
# killall verdict, which sends nothing; the real functions are called only
# with a name no process has.
killall_allowed Dock
killall_allowed -q Dock
killall_allowed -u someone Finder
killall_allowed Dock Finder
killall_refused SomeApplication
killall_refused
killall_refused -q
killall_refused -u
killall_refused -u Dock
killall_refused -9 Dock
killall_refused -KILL Dock
killall_refused -m 'D.*'
killall_refused Dock SomeApplication
killall_refused 'Dock Finder'
killall_refused ''
message="$(killall agent-kill-guard-no-such-process 2>&1)" && fail "killall of an unknown name was not refused"
case "$message" in
  "kill guard: refused"*) ;;
  *) fail "killall was not refused by the guard: $message" ;;
esac
message="$(pkill -x agent-kill-guard-no-such-process 2>&1)" && fail "pkill was not refused"
case "$message" in
  "kill guard: refused"*) ;;
  *) fail "pkill was not refused by the guard: $message" ;;
esac

# 11. The guard's interface agents are the command guard's.
if [ -n "$expected_ui_agents" ] && [ "$__agent_kill_guard_ui_agents" != "$expected_ui_agents" ]; then
  fail "interface agents differ: guard has '$__agent_kill_guard_ui_agents', command guard has '$expected_ui_agents'"
fi

# 12. A non-interactive bash loads the guard through BASH_ENV, before a script
# that runs under `set -eu`.
if [ -n "${BASH_VERSION-}" ]; then
  if ! printf 'set -eu\ntypeset -f kill >/dev/null\n' |
    AGENT_KILL_GUARD=1 BASH_ENV="$guard" "$BASH" -s; then
    fail "bash did not load the guard through BASH_ENV"
  fi
  if printf 'typeset -f kill >/dev/null\n' | env -u AGENT_KILL_GUARD BASH_ENV="$guard" "$BASH" -s; then
    fail "bash loaded the guard through BASH_ENV without the marker"
  fi
fi

if [ "$failures" -gt 0 ]; then
  printf '%s failure(s)\n' "$failures" >&2
  exit 1
fi
echo "kill-guard tests passed"
