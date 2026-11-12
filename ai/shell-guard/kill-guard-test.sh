# Tests for kill-guard.sh. Run as:
#   <shell> kill-guard-test.sh <absolute path to kill-guard.sh> [NAMES [LOADER...]]
# where <shell> is each shell the guard must work in (bash 5, bash 3.2, zsh),
# NAMES, when given, is the command guard's list of interface agents, sorted
# and joined by single spaces, which the guard's own list must equal, and
# the LOADERs are the values the clients give `BASH_FUNC_kill%%`,
# `BASH_FUNC_pkill%%` and `BASH_FUNC_killall%%` (../default.nix).
#
# Safety of the test itself. A real signal goes only to a process this test
# started, even if the guard under test is broken:
#   - a target that must never be signalled (-1, a group found in the process
#     table) is only ever given to a VERDICT function, which sends nothing;
#   - the real `kill` is called only with processes and groups started below,
#     and only after checking that `kill` is the guard's function;
#   - the guard's `pkill` and `killall` are called with no argument at all,
#     so even the real programs would only print their usage, and only while
#     stubs of both stand first on PATH (checked, or the calls are skipped),
#     so a guard that wrongly forwarded is seen in the stub's record.

guard="$1"
expected_ui_agents="${2-}"
loader="${3-}"
pattern_loader="${4-}"
name_loader="${5-}"
bin="${guard%/*}/bin"
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
# bash keeps reading options after the first signal, so a probe followed by a
# real signal is a real signal (builtins/kill.def).
refused -s 0 -s TERM -- -1
refused -0 -s TERM -- -1
refused -0 -n 15 -1
# In bash 3.2 `-s` and `-n` do not mark the signal as given, so the number
# after them is a second signal and the last argument the target.
refused -s 0 -15 -- -1
refused -n 0 -15 -- -1
refused -0 -15 -- -1
refused -0 -1
refused -TERM -l -1
# zsh takes any mix of digits and `-` for a number and narrows it to 32 bits
# (Src/jobs.c, isanum and bin_kill), so this spelling of -1 has no leading `-`.
refused -TERM -- 4294967295-
refused -0 -- 4294967295-
refused -TERM 12-34
refused -TERM -- some-name
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
allowed -n 0 -- -1
allowed -l
allowed -L
if [ -n "$foreign" ]; then allowed -0 -- "-$foreign"; fi

# 6. Single process ids, jobs and the caller's own group pass.
allowed 12345
allowed -TERM 12345
allowed -s TERM 12345 67890
allowed -9 12345
allowed -TERM ' 12345'
allowed -TERM 000000000012345
allowed -0 12345
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
    # Each form is a plain statement, so `set -eu` is in force inside the
    # strict subshell rather than suspended by a surrounding condition.
    case "$mode" in
      plain)
        kill -TERM -- "-$child"
        sent=$?
        ;;
      subshell)
        (kill -TERM -- "-$child")
        sent=$?
        ;;
      strict)
        (
          set -eu
          kill -TERM -- "-$child"
        )
        sent=$?
        ;;
    esac
    if [ "$sent" != 0 ]; then fail "kill of our own child group returned $sent ($mode)"; fi
  fi
  # 143 is death by SIGTERM: a function that returned success without
  # signalling would leave the sleep to end by itself, with status 0.
  wait "$child" 2>/dev/null
  ended=$?
  if [ "$ended" != 143 ]; then fail "our own child group ended with status $ended, not by our signal ($mode)"; fi
done

# 8. The real function on one child process id.
/bin/sleep 60 &
child=$!
kill "$child" || fail "kill of our own child returned failure"
wait "$child" 2>/dev/null
ended=$?
if [ "$ended" != 143 ]; then fail "our own child ended with status $ended, not by our signal"; fi

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
# killall verdict, which sends nothing. The guard's own functions are then
# called with no argument: a function that wrongly forwarded would run a stub
# standing first on PATH, and the real programs, given nothing to match,
# would only print their usage.
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
saved_path="$PATH"
stubs="$(mktemp -d "${TMPDIR:-/tmp}/kill-guard-test.XXXXXX")" || stubs=''
stubbed=0
if [ -n "$stubs" ] && [ -d "$stubs" ]; then
  stubbed=1
  for name in pkill killall; do
    printf '#!/bin/sh\necho "$0 $*" >> "%s/called"\n' "$stubs" >"$stubs/$name" && chmod +x "$stubs/$name"
    if [ ! -x "$stubs/$name" ]; then stubbed=0; fi
  done
  PATH="$stubs:$PATH"
  hash -r
  # What the shell would run for each name once the guard's function is out
  # of the way must be the stub.
  for name in pkill killall; do
    if [ "$(
      unset -f "$name"
      command -v "$name"
    )" != "$stubs/$name" ]; then stubbed=0; fi
  done
fi
if [ "$stubbed" != 1 ]; then
  fail "could not put the terminator stubs first on PATH; the guard's functions were not called"
else
  message="$(killall 2>&1)" && fail "killall was not refused"
  case "$message" in
    "kill guard: refused"*) ;;
    *) fail "killall was not refused by the guard: $message" ;;
  esac
  message="$(pkill 2>&1)" && fail "pkill was not refused"
  case "$message" in
    "kill guard: refused"*) ;;
    *) fail "pkill was not refused by the guard: $message" ;;
  esac
  if [ -e "$stubs/called" ]; then fail "a refused terminator was still run: $(cat "$stubs/called")"; fi
fi
PATH="$saved_path"
hash -r
if [ -n "$stubs" ] && [ -d "$stubs" ]; then rm -r "$stubs"; fi

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
  # Without what this shell exports (13) or a client's loader.
  if (
    export -n -f kill
    printf 'typeset -f kill >/dev/null\n' |
      env -u AGENT_KILL_GUARD -u 'BASH_FUNC_kill%%' BASH_ENV="$guard" "$BASH" -s
  ); then
    fail "bash loaded the guard through BASH_ENV without the marker"
  fi
  # 13. ... and exports it, so an `sh` below it (make, npm scripts, Python's
  # `shell=True`), which reads no BASH_ENV, has it too.
  if ! printf '/bin/sh -s <<"EOS"\ntypeset -f kill >/dev/null && typeset -f __agent_kill_guard_verdict >/dev/null\nEOS\n' |
    AGENT_KILL_GUARD=1 BASH_ENV="$guard" "$BASH" -s; then
    fail "an sh below a guarded bash did not inherit the guard"
  fi
fi

# 14. A single process id: one this shell started passes; an application this
# shell did not start is refused. Verdicts only.
/bin/sleep 60 &
child=$!
allowed -TERM "$child"
builtin kill "$child" 2>/dev/null
wait "$child" 2>/dev/null
# The application is this test's own: sleep, run with the program path of a
# bundle as its argv[0], which is what ps reports. Once orphaned (foreign),
# once as a tool inside a bundle, once as this shell's child.
start_as() {
  /usr/bin/perl -e 'my $p = fork; die "fork failed" unless defined $p; if ($p) { print "$p\n"; exit 0 } close STDOUT; exec { "/bin/sleep" } $ARGV[0], "60"' "$1"
}
application="$(start_as /Applications/Probe.app/Contents/MacOS/Probe)"
tool="$(start_as /Applications/Probe.app/Contents/Resources/probe-cli)"
developer_tool="$(start_as /Applications/Probe.app/Contents/Developer/usr/bin/probe-tool)"
helper="$(start_as "/Applications/Probe.app/Contents/Frameworks/Probe Helper.app/Contents/MacOS/Probe Helper")"
service="$(start_as /Applications/Probe.app/Contents/XPCServices/Probe.xpc/Contents/MacOS/Probe)"
bundled_app="$(start_as /Applications/Probe.app/Contents/Developer/Applications/Viewer.app/Contents/MacOS/Viewer)"
/usr/bin/perl -e 'exec { "/bin/sleep" } $ARGV[0], "60"' /Applications/Probe.app/Contents/MacOS/Probe &
child=$!
tries=0
while [ "$tries" -lt 50 ] && { [ "$(field ppid "$application")" != 1 ] || [ "$(field ppid "$tool")" != 1 ] ||
  [ "$(field ppid "$developer_tool")" != 1 ] || [ "$(field ppid "$helper")" != 1 ] || [ "$(field ppid "$service")" != 1 ] ||
  [ "$(field ppid "$bundled_app")" != 1 ] ||
  [ -z "$(__agent_kill_guard_ps -o comm= -p "$child")" ]; }; do
  tries=$((tries + 1))
  /bin/sleep 0.1
done
case "$(__agent_kill_guard_ps -o comm= -p "$application")" in
  /Applications/Probe.app/Contents/MacOS/Probe) ;;
  *) fail "the test application did not start as one" ;;
esac
refused -TERM "$application"
refused -9 12345 "$application"
allowed -0 "$application"
# Its helpers and services are the application too.
refused -TERM "$helper"
refused -TERM "$service"
# An application shipped inside another's developer tree (Simulator in Xcode).
refused -TERM "$bundled_app"
# A command line tool shipped inside a bundle is not.
allowed -TERM "$tool"
allowed -TERM "$developer_tool"
# The application this shell started itself is its to stop.
allowed -TERM "$child"
builtin kill "$application" "$tool" "$developer_tool" "$helper" "$service" "$bundled_app" "$child" 2>/dev/null
wait "$child" 2>/dev/null

# 16. The guard puts AGENT_KILL_GUARD_BIN first on PATH, once.
path_after="$(
  AGENT_KILL_GUARD_BIN="$bin"
  PATH=/usr/bin:/bin
  . "$guard"
  . "$guard"
  printf '%s' "$PATH"
)"
if [ "$path_after" != "$bin:/usr/bin:/bin" ]; then fail "the guard set PATH to $path_after"; fi

# 17. What the other routes refuse and allow, against a group this test
# started and orphaned (foreign to every shell, see 9) and its own children.
orphan="$(/usr/bin/perl -e 'my $p = fork; die "fork failed" unless defined $p; if ($p) { print "$p\n"; exit 0 } setpgrp(0, 0); close STDOUT; exec "/bin/sleep", "60"')"
case "$orphan" in
  '' | *[!0-9]*) fail "could not start the orphaned test group" ;;
  *)
    if ! leads_own_group "$orphan" 1; then
      fail "the orphaned test process did not become a group leader under process 1"
    else
      # The programs in ./bin, run by a program rather than a shell. Each
      # refusal must be the guard's, not a missing program's.
      message="$(echo "-$orphan" | /usr/bin/xargs "$bin/kill" -TERM -- 2>&1)" &&
        fail "the kill program accepted a group nothing here started"
      case "$message" in "kill guard: refused"*) ;; *) fail "the kill program did not refuse: $message" ;; esac
      message="$("$bin/killall" 2>&1)" && fail "the killall program was not refused"
      case "$message" in "kill guard: refused"*) ;; *) fail "the killall program did not refuse: $message" ;; esac
      message="$("$bin/pkill" 2>&1)" && fail "the pkill program was not refused"
      case "$message" in "kill guard: refused"*) ;; *) fail "the pkill program did not refuse: $message" ;; esac
      # An `sh` whose only guard is the clients' loader in its environment.
      if [ -n "$loader" ]; then
        printf 'kill -TERM -- -%s\n' "$orphan" >"${TMPDIR:-/tmp}/kill-guard-loader.$$"
        if env -u BASH_ENV AGENT_KILL_GUARD=1 "BASH_FUNC_kill%%=$loader" \
          /bin/sh "${TMPDIR:-/tmp}/kill-guard-loader.$$" 2>/dev/null; then
          fail "an sh with the loader accepted a group it did not start"
        fi
        rm "${TMPDIR:-/tmp}/kill-guard-loader.$$"
      fi
      if ! alive "$orphan"; then fail "a refused route still signalled the foreign group"; fi
    fi
    builtin kill "$orphan" 2>/dev/null
    ;;
esac
/bin/sleep 60 &
child=$!
"$bin/kill" -TERM "$child" || fail "the kill program refused this shell's own child"
wait "$child" 2>/dev/null
ended=$?
if [ "$ended" != 143 ]; then fail "our own child ended with status $ended, not by the kill program's signal"; fi
# The other two loaders, called with no argument: refused before anything
# runs.
if [ -n "$pattern_loader" ] && [ -n "$name_loader" ]; then
  printf 'pkill\nkillall\n' >"${TMPDIR:-/tmp}/kill-guard-loader.$$"
  message="$(env -u BASH_ENV AGENT_KILL_GUARD=1 "BASH_FUNC_pkill%%=$pattern_loader" "BASH_FUNC_killall%%=$name_loader" \
    /bin/sh "${TMPDIR:-/tmp}/kill-guard-loader.$$" 2>&1)"
  rm "${TMPDIR:-/tmp}/kill-guard-loader.$$"
  case "$message" in
    "kill guard: refused \`pkill \`"*"kill guard: refused \`killall \`"*) ;;
    *) fail "the pkill and killall loaders did not refuse: $message" ;;
  esac
fi
# A loader whose guard is gone refuses rather than ending the shell.
if [ -n "$loader" ]; then
  # The probe of one process id still answers; anything else is refused,
  # and were it not, it would reach a process id nothing can hold.
  printf 'kill -0 $$\necho "probe $?"\nkill -TERM 999999999\necho "still running $?"\n' >"${TMPDIR:-/tmp}/kill-guard-loader.$$"
  missing="$(printf '%s' "$loader" | sed "s|$guard|$guard.gone|g")"
  message="$(env -u BASH_ENV AGENT_KILL_GUARD=1 "BASH_FUNC_kill%%=$missing" /bin/sh "${TMPDIR:-/tmp}/kill-guard-loader.$$" 2>&1)"
  rm "${TMPDIR:-/tmp}/kill-guard-loader.$$"
  case "$message" in
    "probe 0"*"is gone"*"still running 1") ;;
    *) fail "a loader without its guard did not refuse and carry on: $message" ;;
  esac
fi
if [ -n "$loader" ]; then
  printf '/bin/sleep 60 &\nchild=$!\nkill -TERM "$child"\nwait "$child"\n' >"${TMPDIR:-/tmp}/kill-guard-loader.$$"
  env -u BASH_ENV AGENT_KILL_GUARD=1 "BASH_FUNC_kill%%=$loader" /bin/sh "${TMPDIR:-/tmp}/kill-guard-loader.$$" 2>/dev/null
  ended=$?
  rm "${TMPDIR:-/tmp}/kill-guard-loader.$$"
  if [ "$ended" != 143 ]; then fail "an sh with the loader did not signal its own child (status $ended)"; fi
fi

if [ "$failures" -gt 0 ]; then
  printf '%s failure(s)\n' "$failures" >&2
  exit 1
fi
echo "kill-guard tests passed"
