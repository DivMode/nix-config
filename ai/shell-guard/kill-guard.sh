# Sourced by every non-interactive bash (through BASH_ENV) and every zsh
# (through ZDOTDIR's .zshenv) that an agent client starts. It has no shebang
# and must stay valid in bash 3.2, bash 5 and zsh, print nothing, and work
# under `set -eu`: it runs ahead of every script an agent starts.
#
# Why it exists. On 2026-11-11 a delegated worker rewrote a repository script
# to "terminate its whole command tree". The script walked the process table
# with awk, collected 446 process groups (the first was group 1) and ran
# `kill -TERM -- -<group>` for each. Every process the owner had open was
# terminated, in every session. The command guards read the text of a tool
# call; the call was `bash interrupt.sh`, and the kill sat three scripts
# deeper, so nothing saw it (issue #270).
#
# What it does. In these shells `kill` is a function. A signal aimed at a
# process GROUP (a negative target) reaches the builtin only when the group is
# this shell's own, or its leader was started by this shell. `-1` ("every
# process I may signal"), `-0`, and anything that is not a plain group number
# are refused. A signal aimed at one process id or a job (%1) passes through
# unchanged, and so does the probe signal 0, which delivers nothing. `pkill`
# and `killall` choose their targets by pattern, so they are refused, except
# `killall` on the interface agents launchd restarts (the list the command
# guard allows).
#
# It reads the arguments more strictly than the builtins do, because bash and
# zsh disagree and a spelling one of them rejects the other may act on: bash
# keeps reading options after the first signal (`-s 0 -s TERM` sends TERM),
# and zsh takes any mix of digits and `-` for a number and narrows it to 32
# bits (builtins/kill.def; Src/jobs.c, isanum and bin_kill). So one signal
# option is read, and every target must be a job, a process id of at most
# nine digits, or `-` and such a number. Anything else is refused, which also
# refuses a few legitimate oddities (`-n0`, zsh's `-q`, a listing that is not
# the first argument). A probe may name a group only after `--`
# (`kill -0 -- -GROUP`): in bash 3.2 `-s 0 -15` sends signal 15, because `-s`
# and `-n` do not mark the signal as given, so a negative number before `--`
# may be a second signal rather than a target.
#
# The ownership check is a sequence of `ps` lookups, not a held identity: a
# process id reused between two of them, or the main shell exiting under a
# surviving subshell, could mislead it. It narrows a mistake; it does not
# prove ownership.
#
# A single process id passes, unless this shell did not start it and it is
# an application: its program is the one an `.app`, `.xpc` or `.appex` bundle
# runs (`…/Contents/MacOS/…`), its own or a helper nested inside another
# application, and its path does not pass through a bundle's
# `Contents/Resources` or `Contents/Developer/usr`, where command line tools
# shipped with an application live (the Codex CLI, Xcode's tools). The
# owner's applications, which the 2026-11-11 script terminated, are never an
# agent's to signal, and a process an agent started itself descends from its
# shell.
#
# Where it reaches. A bash exports these functions, so every bash below it
# has them, and so does every `sh` (on macOS /bin/sh is bash, which reads no
# BASH_ENV but imports exported functions): the `sh -c` that make, just,
# npm scripts, Python's `shell=True` and Node's `exec` start. The clients
# also put `kill`, `pkill` and `killall` loaders in the environment
# (`shellGuard` in ../default.nix), for an `sh` whose nearest shell is a zsh,
# which cannot export a function. And ./bin, put first on PATH below, holds
# programs of those three names that apply the same verdict, for a program
# that runs `kill` by name without a shell: `xargs kill`, make's direct
# execution of a simple recipe line, `subprocess.run(["pkill", …])`.
#
# What it does not do. `/bin/kill` or `/usr/bin/pkill` by full path, `builtin
# kill`, `command kill`, a program that calls the system call itself (Python's
# os.kill, a compiled binary), an `sh` below Apple's /bin/zsh with no bash in
# between (that zsh drops exported functions from the environment, measured
# 2026-11-12), and a process whose environment was cleared (`env -i`) are not
# intercepted. Agents and the owner's applications run as one user, so the
# system delivers any signal an agent process does send. This stops a mistake
# at the moment it is made; it is not a boundary against intent.

if [ -z "${AGENT_KILL_GUARD-}" ]; then
  return 0 2>/dev/null || true
fi

# The interface agents `killall` may restart. Must equal
# SELF_RESTARTING_UI_AGENTS in ../hooks/nix-only-guard.py; the flake check
# `agent-kill-guard` compares the two.
__agent_kill_guard_ui_agents='ControlCenter Dock Finder SystemUIServer TextInputMenuAgent'
export __agent_kill_guard_ui_agents


# The process table, from the system's own ps. The Nix build that runs this
# file's test cannot execute /bin/ps ("Operation not permitted", observed
# 2026-11-11; /bin/ps is set-user-id root and the build is not, the cause is
# not established), so the ps on PATH is the fallback. With neither, nothing
# is read and every group is treated as foreign.
__agent_kill_guard_ps() {
  /bin/ps "$@" 2>/dev/null || command ps "$@" 2>/dev/null
}

# The process ownership is measured from: this shell. A program in ./bin
# redefines it as the process that ran that program.
__agent_kill_guard_self() {
  printf '%s' "$$"
}

# 0 when process group $1 belongs to this shell: its own group, or a group
# whose leader descends from this shell. A leader that has already exited
# cannot be verified and is treated as foreign. `$$` is the main shell's id
# even inside a subshell, so a subshell may signal what its script started.
__agent_kill_guard_owned() {
  local __akg_found
  __akg_found="$(__agent_kill_guard_ps -o pgid= -p "$(__agent_kill_guard_self)")" || __akg_found=''
  if [ "$1" = "${__akg_found//[^0-9]/}" ]; then
    return 0
  fi
  __agent_kill_guard_descends "$1"
}

# 0 when process $1 is this shell or descends from it.
__agent_kill_guard_descends() {
  local __akg_pid="$1" __akg_self __akg_found __akg_hops=0
  __akg_self="$(__agent_kill_guard_self)"
  case "$__akg_self" in
    '' | 0 | 1 | *[!0-9]*) return 1 ;;
  esac
  while [ "$__akg_hops" -lt 64 ]; do
    if [ "$__akg_pid" = "$__akg_self" ]; then
      return 0
    fi
    __akg_found="$(__agent_kill_guard_ps -o ppid= -p "$__akg_pid")" || __akg_found=''
    __akg_pid="${__akg_found//[^0-9]/}"
    case "$__akg_pid" in
      '' | 0 | 1) return 1 ;;
    esac
    __akg_hops=$((__akg_hops + 1))
  done
  return 1
}

# Prints nothing and returns 0 when `kill "$@"` may run. Otherwise prints the
# reason on stderr and returns 1. It sends no signal, so tests can call it
# with targets that must never be signalled.
__agent_kill_guard_verdict() {
  local __akg_arg __akg_target __akg_number __akg_found __akg_phase=signal __akg_take=0 __akg_probe=0 __akg_ended=0
  for __akg_arg in "$@"; do
    if [ "$__akg_take" = 1 ]; then
      __akg_take=0
      if [ "$__akg_arg" = 0 ]; then __akg_probe=1; fi
      continue
    fi
    if [ "$__akg_phase" = signal ]; then
      # One signal option, and only as the first argument. A later `-s` or
      # `-l` is a target here, and refused as one.
      __akg_phase=targets
      case "$__akg_arg" in
        -l | -L) return 0 ;;
        -0)
          __akg_probe=1
          continue
          ;;
        -s | -n)
          __akg_take=1
          continue
          ;;
        -*) continue ;;
      esac
    elif [ "$__akg_arg" = "--" ]; then
      __akg_ended=1
      continue
    fi
    # bash accepts a number with blanks around it, so " -1" is still -1.
    __akg_target="${__akg_arg//[[:space:]]/}"
    case "$__akg_target" in
      %*) continue ;;
      -*) __akg_number="${__akg_target#-}" ;;
      *) __akg_number="$__akg_target" ;;
    esac
    while [ "${__akg_number#0}" != "$__akg_number" ] && [ -n "${__akg_number#0}" ]; do
      __akg_number="${__akg_number#0}"
    done
    case "$__akg_number" in
      # Ten digits or more is no process id: a shell that narrows it to 32
      # bits could turn it into -1 (zsh's atoi; deliberately not tried live).
      '' | *[!0-9]* | ??????????*)
        printf 'kill guard: refused `kill %s`: the target %s is not a job, a process id or a process group number.\n' \
          "$*" "$__akg_arg" >&2
        return 1
        ;;
    esac
    case "$__akg_target" in
      -*)
        # Signal 0 delivers nothing; it only asks whether the target exists.
        # Before `--` a negative number may be a second signal (see above).
        if [ "$__akg_probe" = 1 ] && [ "$__akg_ended" = 1 ]; then continue; fi
        if [ "$__akg_probe" = 1 ]; then
          printf 'kill guard: refused `kill %s`: probe a process group as `kill -0 -- -GROUP`; before `--`, %s may be read as a signal.\n' \
            "$*" "$__akg_arg" >&2
          return 1
        fi
        if [ "$__akg_number" -le 1 ]; then
          printf 'kill guard: refused `kill %s`: -1 signals every process this user owns, and -0 or -1 is never a group this shell started.\n' \
            "$*" >&2
          return 1
        fi
        if ! __agent_kill_guard_owned "$__akg_number"; then
          printf 'kill guard: refused `kill %s`: process group %s was not started by this shell. Signal the process ids you started and wait for them; never a group you looked up.\n' \
            "$*" "$__akg_number" >&2
          return 1
        fi
        ;;
      *)
        if [ "$__akg_probe" = 1 ] || [ "$__akg_number" = 0 ]; then continue; fi
        if __agent_kill_guard_descends "$__akg_number"; then continue; fi
        __akg_found="$(__agent_kill_guard_ps -o comm= -p "$__akg_number")" || __akg_found=''
        case "$__akg_found" in
          */Contents/Resources/* | */Contents/Developer/usr/*) ;;
          *.app/Contents/MacOS/* | *.xpc/Contents/MacOS/* | *.appex/Contents/MacOS/*)
            printf 'kill guard: refused `kill %s`: process %s is an application (%s) this shell did not start. A program an earlier command started is stopped through what started it: the background task, or the `membrake exec` process whose id it recorded.\n' \
              "$*" "$__akg_number" "$__akg_found" >&2
            return 1
            ;;
        esac
        ;;
    esac
  done
  return 0
}

# The same for `killall "$@"`: 0 only for `killall [-q] [-u USER] NAME...`
# where every NAME is an interface agent. It sends no signal.
__agent_kill_guard_killall_verdict() {
  local __akg_arg __akg_take=0 __akg_names=0
  for __akg_arg in "$@"; do
    if [ "$__akg_take" = 1 ]; then
      __akg_take=0
      continue
    fi
    case "$__akg_arg" in
      -q) continue ;;
      -u)
        __akg_take=1
        continue
        ;;
      '' | -* | *[!A-Za-z]*) ;;
      *)
        case " $__agent_kill_guard_ui_agents " in
          *" $__akg_arg "*)
            __akg_names=1
            continue
            ;;
        esac
        ;;
    esac
    printf 'kill guard: refused `killall %s`: it chooses its targets by name. Signal the process ids you started.\n' "$*" >&2
    return 1
  done
  if [ "$__akg_names" != 1 ]; then
    printf 'kill guard: refused `killall %s`: no process name given.\n' "$*" >&2
    return 1
  fi
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
  __agent_kill_guard_killall_verdict "$@" || return 1
  command killall "$@"
}

# Every bash below this one, and every `sh` (bash again), inherits the guard.
# zsh cannot export a function; see the loaders in ../default.nix.
if [ -n "${BASH_VERSION-}" ]; then
  export -f kill pkill killall __agent_kill_guard_ps __agent_kill_guard_self \
    __agent_kill_guard_owned __agent_kill_guard_descends \
    __agent_kill_guard_verdict __agent_kill_guard_killall_verdict
fi

# The programs of the same names (./bin), first on PATH, for a program that
# runs `kill`, `pkill` or `killall` without a shell. The clients name the
# directory in AGENT_KILL_GUARD_BIN.
if [ -n "${AGENT_KILL_GUARD_BIN-}" ] && [ -d "$AGENT_KILL_GUARD_BIN" ]; then
  case ":${PATH-}:" in
    *":$AGENT_KILL_GUARD_BIN:"*) ;;
    *)
      PATH="$AGENT_KILL_GUARD_BIN${PATH:+:$PATH}"
      export PATH
      ;;
  esac
fi
