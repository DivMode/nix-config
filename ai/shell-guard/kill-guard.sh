# Sourced by every non-interactive bash (through BASH_ENV) and every zsh
# (through ZDOTDIR's .zshenv) that an agent client starts. It has no shebang
# and must stay valid in bash 3.2, bash 5 and zsh.
#
# Why it exists. On 2026-11-11 a delegated worker rewrote a repository script
# to "terminate its whole command tree". The script walked the process table
# with awk, collected 446 process groups (the first was group 1) and ran
# `kill -TERM -- -<group>` for each. Every process the owner had open was
# terminated, in every session. The command guards read the text of a tool
# call; the call was `bash interrupt.sh`, and the kill sat three scripts
# deeper, so nothing saw it.
#
# What it does. In these shells `kill` is a function. A signal aimed at a
# process GROUP (a negative target) reaches the builtin only when the group is
# this shell's own, or its leader was started by this shell; group 1 ("every
# process I may signal") and group 0 forms other than the caller's own group
# are refused. A signal aimed at one process id, a job (%1), or the probe
# signal 0 passes through unchanged. `pkill` and `killall` choose their
# targets by pattern, so they are refused outright, except `killall` on the
# interface agents launchd restarts (the list the command guard allows).
#
# What it does not do. It covers the shell builtin, which is what scripts use.
# A program that calls the system call itself (Python's os.kill, a compiled
# binary), `/bin/kill`, `builtin kill` and `sh` (bash in POSIX mode reads no
# BASH_ENV) are not intercepted. This stops a mistake at the moment it is
# made; it is not a boundary against intent. The boundary would be a separate
# user for agents, which this machine deliberately does not have.

if [ -z "${AGENT_KILL_GUARD-}" ]; then
  return 0 2>/dev/null || true
fi

# 0 when process group $1 belongs to this shell: its own group, or a group
# whose leader descends from this shell. A leader that has already exited
# cannot be verified and is treated as foreign.
__agent_kill_guard_owned() {
  local __akg_group="$1" __akg_pid="$1" __akg_parent __akg_own __akg_hops=0
  __akg_own="$(/bin/ps -o pgid= -p "$$" 2>/dev/null)"
  __akg_own="${__akg_own//[^0-9]/}"
  if [ -n "$__akg_own" ] && [ "$__akg_group" = "$__akg_own" ]; then
    return 0
  fi
  while [ "$__akg_hops" -lt 64 ]; do
    if [ "$__akg_pid" = "$$" ]; then
      return 0
    fi
    __akg_parent="$(/bin/ps -o ppid= -p "$__akg_pid" 2>/dev/null)"
    __akg_parent="${__akg_parent//[^0-9]/}"
    case "$__akg_parent" in
      '' | 0 | 1) return 1 ;;
    esac
    __akg_pid="$__akg_parent"
    __akg_hops=$((__akg_hops + 1))
  done
  return 1
}

# Prints nothing and returns 0 when `kill "$@"` may run. Otherwise prints the
# reason on stderr and returns 1. It sends no signal, so tests can call it
# with targets that must never be signalled.
__agent_kill_guard_verdict() {
  local __akg_arg __akg_phase=signal __akg_take=0 __akg_probe=0 __akg_number
  for __akg_arg in "$@"; do
    if [ "$__akg_take" = 1 ]; then
      __akg_take=0
      if [ "$__akg_arg" = 0 ]; then __akg_probe=1; fi
      continue
    fi
    if [ "$__akg_phase" = signal ]; then
      __akg_phase=targets
      case "$__akg_arg" in
        -l | -L | --list | --table) return 0 ;;
        -s | -n)
          __akg_take=1
          continue
          ;;
        --) continue ;;
        -0)
          __akg_probe=1
          continue
          ;;
        -*) continue ;;
      esac
    elif [ "$__akg_arg" = "--" ]; then
      continue
    fi
    case "$__akg_arg" in
      -*)
        # Signal 0 delivers nothing; it only asks whether the target exists.
        if [ "$__akg_probe" = 1 ]; then continue; fi
        __akg_number="${__akg_arg#-}"
        case "$__akg_number" in
          '' | *[!0-9]*)
            printf 'kill guard: refused `kill %s`: the target %s is not a process group number.\n' \
              "$*" "$__akg_arg" >&2
            return 1
            ;;
        esac
        if [ "$__akg_number" -le 1 ] 2>/dev/null; then
          printf 'kill guard: refused `kill %s`: %s signals every process this user owns.\n' \
            "$*" "$__akg_arg" >&2
          return 1
        fi
        if ! __agent_kill_guard_owned "$__akg_number"; then
          printf 'kill guard: refused `kill %s`: process group %s was not started by this shell. Signal the process ids you started and wait for them; never a group you looked up.\n' \
            "$*" "$__akg_number" >&2
          return 1
        fi
        ;;
    esac
  done
  return 0
}

kill() {
  __agent_kill_guard_verdict "$@" || return 1
  builtin kill "$@"
}

pkill() {
  printf 'kill guard: refused `pkill %s`: it chooses its targets by pattern. Signal the process ids you started.\n' "$*" >&2
  return 1
}

killall() {
  local __akg_arg __akg_take=0 __akg_names=0
  for __akg_arg in "$@"; do
    if [ "$__akg_take" = 1 ]; then
      __akg_take=0
      continue
    fi
    case "$__akg_arg" in
      -q) ;;
      -u) __akg_take=1 ;;
      Dock | Finder | SystemUIServer | ControlCenter | TextInputMenuAgent) __akg_names=1 ;;
      *)
        printf 'kill guard: refused `killall %s`: it chooses its targets by name. Signal the process ids you started.\n' "$*" >&2
        return 1
        ;;
    esac
  done
  if [ "$__akg_names" != 1 ]; then
    printf 'kill guard: refused `killall %s`: no process name given.\n' "$*" >&2
    return 1
  fi
  command killall "$@"
}
