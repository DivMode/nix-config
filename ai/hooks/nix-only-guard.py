#!/usr/bin/env python3
"""PreToolUse guard: block machine mutation that bypasses Nix.

Reads the hook payload on stdin, inspects the Bash command, and denies any
segment that changes macOS system/application state or installs software
outside the Nix/nix-darwin flow. Read-only inspection is always allowed.

The rule this enforces: desired state is declared in the Nix configuration and
applied by `darwin-rebuild switch`. Nothing else may touch the machine.
"""

import json
import os
import re
import shlex
import sys

HOME = os.path.expanduser("~")

# Commands that are the sanctioned way to change the machine.
ALLOWED_PROGRAMS = {"darwin-rebuild", "nix", "nix-build", "nix-env", "nix-shell",
                    "nix-store", "nix-instantiate", "nix-collect-garbage",
                    "home-manager", "nixos-rebuild"}

# Wrappers to peel off before identifying the real program.
WRAPPERS = {"sudo", "env", "command", "exec", "nohup", "time", "doas"}

PROTECTED_PATH_RE = re.compile(
    r"(?:^|[\s\"'=])(?:~|\$HOME|\$\{HOME\}|" + re.escape(HOME) + r")/"
    r"(?:Library|\.config)(?:/|\b)"
)

# Programs that write to whatever path they are given.
PATH_WRITERS = {"rm", "mv", "cp", "install", "mkdir", "touch", "tee", "ln",
                "chmod", "chown", "rsync", "truncate", "unlink", "rmdir"}

# macOS interface agents that launchd relaunches within a second and that hold
# no user work: restarting one only redraws the Dock, Finder windows, or the
# menu bar. The owner allowed these on 2026-10-06 so a refresh (a stale Dock
# icon) does not need them to type the command themselves. Applications and
# daemons stay blocked: their restarts belong in an activation entry that
# compares before and after.
SELF_RESTARTING_UI_AGENTS = {"Dock", "Finder", "SystemUIServer", "ControlCenter",
                             "TextInputMenuAgent"}


def restarts_only_ui_agents(args):
    """True for `killall [-q] [-u USER] NAME...` where every NAME is one of
    SELF_RESTARTING_UI_AGENTS. Any other flag — a signal, -m pattern matching,
    -c, -t — or any other name keeps the command blocked."""
    names = []
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "-q":
            i += 1
        elif arg == "-u" and i + 1 < len(args):
            i += 2
        elif arg.startswith("-"):
            return False
        else:
            names.append(arg)
            i += 1
    return bool(names) and all(name in SELF_RESTARTING_UI_AGENTS for name in names)


def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


# A heredoc introducer: <<EOF, <<-EOF, <<'EOF', << "EOF".
HEREDOC_RE = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")

# Interpreters that EXECUTE a heredoc body instead of consuming it as data.
SHELL_INTERPRETERS = {"bash", "sh", "zsh", "dash", "ksh", "fish", "csh", "tcsh"}


def strip_heredoc_bodies(command):
    """Remove heredoc bodies that are DATA, so they are not read as commands.

    This is the guard's single largest source of false positives, and every
    instance looks the same: text that merely NAMES a blocked mechanism gets
    sliced up by split_segments() and checked as though it were being run.

    Two things routinely carry such text, and neither changes the machine:

      - `git commit -F -` heredocs. A commit message explaining why a rule
        exists has to name the thing it forbids. Twice already, a commit
        describing this very guard was blocked by it.
      - `python3 - <<'PY' ... PY` heredocs that WRITE a Nix module. Declaring
        a machine change in the repository is what the guard's own denial
        message instructs you to do, so blocking it told the author to do the
        one thing it then refused to let them do.

    Bodies fed to a shell are deliberately NOT stripped. `bash <<'EOF'` really
    does execute what it contains, so that text is a command and must stay
    checked. The distinction is effect, not spelling.
    """
    lines = command.split("\n")
    kept = []
    index = 0
    while index < len(lines):
        line = lines[index]
        kept.append(line)
        index += 1

        terminators = [match.group(2) for match in HEREDOC_RE.finditer(line)]
        if not terminators:
            continue

        # If this line hands the body to a shell, the body is executable and
        # every line of it stays in scope for checking.
        words = re.findall(r"[A-Za-z0-9_./-]+", line)
        if any(os.path.basename(word) in SHELL_INTERPRETERS for word in words):
            continue

        for terminator in terminators:
            while index < len(lines) and lines[index].strip() != terminator:
                index += 1
            if index < len(lines):
                index += 1  # drop the terminator line itself
    return "\n".join(kept)


def split_segments(command):
    """Split a compound command into individually-checkable segments."""
    command = strip_heredoc_bodies(command)
    return [s for s in re.split(r"&&|\|\||[;&|\n]", command) if s.strip()]


# The owner's credentials are not the repository's. On 2026-09-14 an agent hit
# the 1Password service account's quota and "worked around" it by unsetting the
# token so `op` fell back to the signed-in desktop session, which raised an
# authorisation dialog on the owner's screen for every process. These rules
# deny that class of command before it runs: invoking the `op` CLI at all,
# unsetting or overriding an OP_* variable, and reading ~/.config/op. Secrets
# reach a repository only through its own loader (Connect); a failure there is
# a stop, never a search for another credential.
OP_VARIABLE_RE = re.compile(
    r"(?:^|[\s;&|(])(?:env\s+(?:-\S+\s+)*-u\s+OP_|unset\s+(?:-\S+\s+)*OP_|"
    r"(?:export\s+)?OP_(?:SERVICE_ACCOUNT_TOKEN|CONNECT_HOST|CONNECT_TOKEN|SESSION_[A-Za-z0-9_]+)=)"
)
OP_CONFIG_RE = re.compile(
    r"(?:~|\$HOME|\$\{HOME\}|" + re.escape(HOME) + r")/\.config/op(?:/|\b)"
)


# Connect ADMINISTRATION the owner allowed agents to run on 2026-10-07: list
# servers and their vaults, grant a server a vault, and issue a token. Connect
# itself cannot grant access, and neither the SDK nor a service account can,
# so this is the only path besides the 1Password website. Everything that
# reads or writes secret data stays blocked — data goes through Connect only —
# and so does anything destructive (deleting a token, server or vault access).
OP_CONNECT_ADMIN = {("server", "list"), ("vault", "list"), ("vault", "grant"), ("token", "create")}


def is_connect_administration(raw):
    """True for `op connect <noun> <verb>` where (noun, verb) is allowed."""
    try:
        words = shlex.split(raw)
    except ValueError:
        return False
    for i, word in enumerate(words):
        if os.path.basename(word) == "op":
            positional = []
            for rest in words[i + 1:]:
                if rest.startswith("-"):
                    break
                positional.append(rest)
            return (len(positional) >= 3 and positional[0] == "connect"
                    and (positional[1], positional[2]) in OP_CONNECT_ADMIN)
    return False


def credential_boundary(raw, prog):
    """Deny commands that reach past the repository's secrets loader."""
    if prog == "op" and is_connect_administration(raw):
        return None
    if prog == "op":
        return ("Blocked: the 1Password CLI (`op`) is never invoked from an agent command. "
                "Secrets come only through the repository's own loader (Connect). "
                "If it fails, stop and report; do not find another credential.")
    if OP_VARIABLE_RE.search(raw):
        return ("Blocked: unsetting or overriding an OP_* variable. The repository's secrets "
                "loader owns 1Password access; nothing may strip its token or point it "
                "at another session.")
    if OP_CONFIG_RE.search(raw):
        return ("Blocked: ~/.config/op holds the owner's 1Password credentials. Agents do "
                "not read or write it; the repository's loader reads what it needs itself.")
    return None


def check(segment):
    raw = segment.strip()
    try:
        tokens = shlex.split(raw)
    except ValueError:
        tokens = raw.split()
    if not tokens:
        return None

    # Peel wrappers and leading VAR=value assignments.
    while tokens:
        head = os.path.basename(tokens[0])
        if head in WRAPPERS or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tokens[0]):
            tokens = tokens[1:]
            # A wrapper's own flags (`env -u NAME`, `env -i`, `sudo -E`,
            # `nohup -p`) are not the program; skip them, and the argument of
            # the flags that take one, so the real program is what gets judged.
            while tokens and tokens[0].startswith("-"):
                flag = tokens.pop(0)
                if flag in {"-u", "--unset", "-C", "--chdir", "-S", "--split-string",
                            "-p", "--prompt", "-g", "--group", "-h", "--host"} and tokens:
                    tokens.pop(0)
            continue
        break
    if not tokens:
        return None

    prog = os.path.basename(tokens[0])
    args = tokens[1:]
    flagless = [a for a in args if not a.startswith("-")]
    sub = flagless[0] if flagless else ""

    credential = credential_boundary(raw, prog)
    if credential:
        return credential

    if prog in ALLOWED_PROGRAMS:
        return None

    def blocked(what):
        return (f"Blocked: `{raw.strip()}`\n\n{what} changes the machine outside Nix. "
                f"Declare it in the nix-config repo and apply with `darwin-rebuild switch`.")

    if prog == "defaults" and any(t in ("write", "delete", "rename", "import") for t in args):
        return blocked("`defaults write/delete`")
    if prog == "tccutil":
        return blocked("`tccutil`")
    if prog == "launchctl" and sub in {"load", "unload", "kickstart", "bootstrap",
                                       "bootout", "enable", "disable", "start",
                                       "stop", "remove", "submit", "setenv", "unsetenv"}:
        return blocked(f"`launchctl {sub}`")
    if prog == "killall" and restarts_only_ui_agents(args):
        return None
    if prog in {"killall", "pkill"}:
        return blocked(f"`{prog}`")
    if prog == "brew" and sub in {"install", "uninstall", "remove", "rm", "upgrade",
                                  "reinstall", "tap", "untap", "link", "unlink", "bundle"}:
        return blocked(f"`brew {sub}`")
    if prog == "mas" and sub in {"install", "upgrade", "uninstall"}:
        return blocked(f"`mas {sub}`")
    if prog in {"npm", "pnpm", "yarn", "bun"} and sub in {"install", "i", "add"} \
            and any(a in ("-g", "--global") for a in args):
        return blocked(f"`{prog}` global install")
    if prog in {"pip", "pip3"} and sub == "install":
        return blocked("`pip install`")
    if prog in {"cargo", "gem", "go"} and sub == "install":
        return blocked(f"`{prog} install`")
    if prog == "softwareupdate":
        return blocked("`softwareupdate`")
    if prog == "systemextensionsctl" and sub != "list":
        return blocked("`systemextensionsctl`")
    if prog == "csrutil" and sub != "status":
        return blocked("`csrutil`")
    if prog == "scutil" and any(a.startswith("--set") for a in args):
        return blocked("`scutil --set`")
    # duti -x/-l only query the handler database; -s writes it.
    if prog == "duti" and not any(a.startswith(("-x", "-l")) for a in args):
        return blocked("`duti -s`")
    if prog in {"chflags", "nvram", "spctl", "dscl", "diskutil"}:
        return blocked(f"`{prog}`")
    if prog == "mdutil" and any(a in ("-i", "-E", "-a") for a in args):
        return blocked("`mdutil`")

    # Writes aimed at user application state.
    if prog in PATH_WRITERS and PROTECTED_PATH_RE.search(raw):
        return blocked(f"`{prog}` into ~/Library or ~/.config")
    if re.search(r">>?\s*(?:~|\$HOME|\$\{HOME\}|" + re.escape(HOME) + r")/(?:Library|\.config)/", raw):
        return blocked("shell redirection into ~/Library or ~/.config")

    return None


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    command = (payload.get("tool_input") or {}).get("command") or ""
    if not command:
        sys.exit(0)

    for segment in split_segments(command):
        reason = check(segment)
        if reason:
            deny(reason)

    sys.exit(0)


if __name__ == "__main__":
    main()
