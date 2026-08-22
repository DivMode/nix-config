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
            continue
        break
    if not tokens:
        return None

    prog = os.path.basename(tokens[0])
    args = tokens[1:]
    flagless = [a for a in args if not a.startswith("-")]
    sub = flagless[0] if flagless else ""

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
