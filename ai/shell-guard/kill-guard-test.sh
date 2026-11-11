# Tests for kill-guard.sh. Run as: <shell> kill-guard-test.sh <path to kill-guard.sh>
# where <shell> is each shell the guard must work in (bash and zsh).
#
# Safety of the test itself: a target that must never be signalled (group 1,
# a foreign group) is only ever given to the VERDICT function, which sends no
# signal. The real `kill` function is exercised only on processes this test
# started.

guard="$1"
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

# 1. Without the marker the file defines nothing.
unset AGENT_KILL_GUARD
. "$guard"
if command -v __agent_kill_guard_verdict >/dev/null 2>&1; then
  fail "guard active without AGENT_KILL_GUARD"
fi

AGENT_KILL_GUARD=1
. "$guard"
command -v __agent_kill_guard_verdict >/dev/null 2>&1 || {
  echo "FAIL: guard not defined with AGENT_KILL_GUARD=1" >&2
  exit 1
}

# 2. Every spelling of "all my processes" and of group 1 is refused.
refused -- -1
refused -TERM -1
refused -TERM -- -1
refused -9 -1
refused -s TERM -1
refused -s TERM -- -1
refused -n 15 -1
refused -KILL -- -1 -2
refused -- -0
refused -TERM -- -abc
refused -TERM -- '-$group'

# 3. A process group this shell did not start is refused. launchd's own
# children lead groups that no test shell can be an ancestor of; group 1 is
# covered above, so look for another live group led by a child of process 1.
foreign="$(/bin/ps -axo pid=,ppid=,pgid= | awk '$2 == 1 && $1 == $3 && $1 > 1 { print $1; exit }')"
if [ -n "$foreign" ]; then
  refused -TERM -- "-$foreign"
  refused -KILL "-$foreign"
  # The incident's shape: a long list where only some entries are foreign.
  refused -TERM -- "-$foreign" -1
else
  echo "note: no foreign process group found to test against" >&2
fi

# 4. Probes and listings deliver nothing, so they pass even for foreign targets.
allowed -0 -- -1
allowed -s 0 -- -1
allowed -l
allowed -L
if [ -n "$foreign" ]; then allowed -0 -- "-$foreign"; fi

# 5. Single process ids, jobs and the caller's own group pass.
allowed 12345
allowed -TERM 12345
allowed -s TERM 12345 67890
allowed -9 12345
allowed -TERM %1
allowed 0
own="$(/bin/ps -o pgid= -p "$$")"
own="${own//[^0-9]/}"
if [ "$own" -gt 1 ]; then allowed -TERM -- "-$own"; fi

# 6. A group this shell started is allowed, and the real function signals it.
# perl's setpgrp gives the child its own group whose leader is our child.
/usr/bin/perl -e 'setpgrp(0, 0); exec "/bin/sleep", "300"' &
child=$!
tries=0
while [ "$tries" -lt 50 ]; do
  group="$(/bin/ps -o pgid= -p "$child" 2>/dev/null)"
  group="${group//[^0-9]/}"
  [ "$group" = "$child" ] && break
  tries=$((tries + 1))
  /bin/sleep 0.1
done
if [ "$group" != "$child" ]; then
  fail "test child did not become a group leader"
  builtin kill "$child" 2>/dev/null
else
  allowed -TERM -- "-$child"
  kill -TERM -- "-$child" || fail "kill of our own child group returned failure"
  wait "$child" 2>/dev/null
  if builtin kill -0 "$child" 2>/dev/null; then fail "our own child group survived"; fi
fi

# 7. The real function on one child process id.
/bin/sleep 300 &
child=$!
kill "$child" || fail "kill of our own child returned failure"
wait "$child" 2>/dev/null
if builtin kill -0 "$child" 2>/dev/null; then fail "our own child survived"; fi

# 8. A refusal returns non-zero from the real function and signals nothing.
/bin/sleep 300 &
child=$!
if kill -TERM -- -1 "$child" 2>/dev/null; then fail "kill accepted a list containing -1"; fi
if ! builtin kill -0 "$child" 2>/dev/null; then fail "a refused kill still signalled a listed process"; fi
builtin kill "$child" 2>/dev/null
wait "$child" 2>/dev/null

# 9. Pattern-based terminators are refused; the interface agents stay allowed
# in principle (checked through the refusal path only: nothing is restarted).
if pkill -f anything 2>/dev/null; then fail "pkill was not refused"; fi
if killall SomeApplication 2>/dev/null; then fail "killall of an application was not refused"; fi
if killall 2>/dev/null; then fail "killall without a name was not refused"; fi
if killall -9 Dock 2>/dev/null; then fail "killall with a signal flag was not refused"; fi

if [ "$failures" -gt 0 ]; then
  printf '%s failure(s)\n' "$failures" >&2
  exit 1
fi
echo "kill-guard tests passed"
