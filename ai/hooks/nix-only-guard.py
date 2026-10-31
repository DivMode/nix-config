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
import subprocess
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


# uv is the only owner of Python (global policy). Its interpreters refuse pip
# installs (EXTERNALLY-MANAGED); these are the agent commands that install into
# an interpreter anyway, or defeat that refusal, as a project recipe's
# `pip3 install --break-system-packages` did on 2026-10-06.
PIP_PROGRAM_RE = re.compile(r"pip(?:3(?:\.\d+)?)?")
PYTHON_PROGRAM_RE = re.compile(r"python(?:3(?:\.\d+)?)?")


def installs_python_packages_outside_uv(prog, args, raw):
    if PYTHON_PROGRAM_RE.fullmatch(prog):
        if "-m" not in args or args[args.index("-m") + 1:args.index("-m") + 2] != ["pip"]:
            return False
        args = args[args.index("-m") + 2:]
    elif not PIP_PROGRAM_RE.fullmatch(prog) and prog != "uv":
        return False
    if "--break-system-packages" in args or "PIP_BREAK_SYSTEM_PACKAGES" in raw:
        return True
    flagless = [a for a in args if not a.startswith("-")]
    if prog == "uv":
        return flagless[:2] == ["pip", "install"] and "--system" in args
    return flagless[:1] == ["install"]


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

# Agent shells run with OP_BIOMETRIC_UNLOCK_ENABLED=false so that no command,
# typed or buried in a script, can reach the 1Password desktop app and raise a
# Touch ID prompt (2026-10-31). Setting it, unsetting it, or starting from an
# empty environment (`env -i`) all hand a buried `op` call the app again. Judged
# on the parsed words of the segment, so quoting cannot hide an assignment and
# a command that only prints or searches the text (echo, grep) is not denied.
BIOMETRIC = "OP_BIOMETRIC_UNLOCK_ENABLED"
DECLARERS = {"export", "declare", "typeset", "local", "readonly"}


def reenables_app_integration(tokens):
    """True when this segment's words would set, unset or drop BIOMETRIC."""
    i = 0
    while i < len(tokens):
        word = tokens[i]
        if word.startswith(BIOMETRIC + "="):
            return True  # a leading assignment, before any program
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", word):
            i += 1
            continue
        head = os.path.basename(word)
        rest = tokens[i + 1:]
        if head == "unset":
            return BIOMETRIC in rest
        if head in DECLARERS:
            return any(arg == BIOMETRIC or arg.startswith(BIOMETRIC + "=") for arg in rest)
        if head == "env":
            j = 0
            while j < len(rest):
                arg = rest[j]
                if arg in {"-i", "--ignore-environment", "-"}:
                    return True
                if arg in {"-u", "--unset"}:
                    if j + 1 < len(rest) and rest[j + 1] == BIOMETRIC:
                        return True
                    j += 2
                    continue
                if arg in {f"-u{BIOMETRIC}", f"--unset={BIOMETRIC}"} or arg.startswith(BIOMETRIC + "="):
                    return True
                if arg.startswith("-") or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", arg):
                    j += 1
                    continue
                break
            i += 1 + j
            continue
        if head in WRAPPERS:
            i += 1
            while i < len(tokens) and tokens[i].startswith("-"):
                i += 1
            continue
        return False
    return False
OP_CONFIG_RE = re.compile(
    r"(?:~|\$HOME|\$\{HOME\}|" + re.escape(HOME) + r")/\.config/op(?:/|\b)"
)


def credential_boundary(raw, prog):
    """Deny commands that reach past the repository's secrets loader."""
    if prog == "op":
        # Typed 1Password administration used to be allowed here. Agent shells
        # now run with the desktop app integration off, so it could only fail;
        # each owner-approved step has a declared command instead.
        return ("Blocked: the 1Password CLI (`op`) is never invoked from an agent command. "
                "Secrets come only through the repository's own loader (Connect). "
                "Administration has declared commands: `nix-config-connect-item put` to store "
                "or edit an item, and `nix-config-op-admin vault create NAME`, `nix-config-op-admin "
                "item move ITEM --current-vault A --destination-vault B` and `nix-config-op-admin "
                "vault user grant ...` (a vault it created), none of which prompts. Only these ask "
                "for the owner's Touch ID: `nix-config-connect-rotate --add-vault VAULT` (Connect "
                "access), `nix-config-op-owner vault user grant ...` (any other vault), "
                "`nix-config-op-owner connect token delete ...` and the one-time "
                "`nix-config-op-admin setup`. "
                "If one fails, stop and report; do not find another credential.")
    if OP_VARIABLE_RE.search(raw):
        return ("Blocked: unsetting or overriding an OP_* variable. The repository's secrets "
                "loader owns 1Password access; nothing may strip its token or point it "
                "at another session.")
    if OP_CONFIG_RE.search(raw):
        return ("Blocked: ~/.config/op holds the owner's 1Password credentials. Agents do "
                "not read or write it; the repository's loader reads what it needs itself.")
    return None


# Writes to GitHub go through gh, which this configuration wraps so that text
# naming a private project never posts to the public repository
# (scripts/gh-private-names-guard.sh, 2026-10-09). An agent keeps its token, so
# it could still post with its own HTTP request; these rules deny the obvious
# shapes of that in Claude Code. They match command text, so a client written
# to evade them is not stopped — the residual the wrapper's commit names.
GITHUB_API_RE = re.compile(r"(?:api|uploads)\.github\.com|github\.com/api/", re.I)
HTTP_CLIENTS = {"curl", "wget", "http", "https", "httpie", "xh", "xhs"}
WRITE_METHODS = {"POST", "PUT", "PATCH", "DELETE"}
INTERPRETERS_RE = re.compile(r"(?:python[0-9.]*|node|nodejs|deno|bun|ruby|perl|php)")
SCRIPT_WRITE_RE = re.compile(r"\b(?:post|put|patch|delete)\b|method\s*[:=]", re.I)
RAW_GITHUB_WRITE = ("Blocked: a write to the GitHub API outside gh. Use `gh` (`gh api` for "
                    "anything without a subcommand): it is wrapped to refuse private project "
                    "names in text posted to the public repository, and a raw request skips that.")


def raw_github_write(prog, args, raw):
    """True for an HTTP client sending a write to the GitHub API."""
    if prog not in HTTP_CLIENTS or not GITHUB_API_RE.search(raw):
        return False
    if prog == "curl":
        for i, arg in enumerate(args):
            if arg in ("-X", "--request") and i + 1 < len(args):
                if args[i + 1].upper() != "GET":
                    return True
            elif arg.startswith("-X") and len(arg) > 2 and arg[2:].upper() != "GET":
                return True
            elif arg.startswith(("--data", "--json", "--form", "--upload-file")) or \
                    arg in ("-d", "-F", "-T") or (arg[:2] in ("-d", "-F", "-T") and len(arg) > 2):
                return True
        return False
    if prog == "wget":
        return any(a.startswith(("--post-data", "--post-file", "--body-data", "--body-file", "--method"))
                   for a in args)
    # httpie and xh: an explicit write method, or any request item that sends
    # data (field=value, field:=json, field@file) — not a query (name==value)
    # or a header (Name:value).
    positional = [a for a in args if not a.startswith("-")]
    if positional and positional[0].upper() in WRITE_METHODS:
        return True
    return any(re.match(r"[^=:@\s]+(?::=|=(?!=)|@)", a) for a in positional[1:])


# An unquoted heredoc body is expanded by the shell before it is written:
# every `...` and $(...) in it runs as a command. On 2026-10-09 a project
# session wrote a prompt file with `cat > prompt.md <<EOF`, and the Markdown
# code spans in its body ran a test suite, hit a zsh glob error, and left the
# prompt silently garbled. Quoting the delimiter keeps the body literal.
HEREDOC_SUBSTITUTION = ("Blocked: this heredoc's delimiter is unquoted, so the shell runs every "
                        "backtick span and `$(...)` in its body while writing it. Quote the "
                        "delimiter (`<<'EOF'`) so the body stays literal, or write the file with "
                        "the Write tool; to insert a command's output, set a variable first and "
                        "expand `$VAR`.")
HEREDOC_WORD_END = set(" \t\n;&|<>()")
SUBSTITUTION_RE = re.compile(r"`|\$\((?!\()")  # $(( )) is arithmetic, not a command


def heredoc_word(command, i):
    """Read the heredoc word at i: (delimiter after quote removal, quoted, end).
    Any quoting in the word — 'EOF', "EOF", \\EOF — makes the body literal."""
    word, quoted = [], False
    while i < len(command) and command[i] not in HEREDOC_WORD_END:
        if command[i] == "\\":
            word.append(command[i + 1:i + 2])
            quoted, i = True, i + 2
        elif command[i] in "'\"":
            close = command.find(command[i], i + 1)
            close = len(command) if close == -1 else close
            word.append(command[i + 1:close])
            quoted, i = True, close + 1
        else:
            word.append(command[i])
            i += 1
    return "".join(word), quoted, i


def unquoted_heredoc_substitution(command):
    """True when an unquoted heredoc's body contains a backtick or `$(`.

    HEREDOC_RE reads lines without quote context, which would take a `<<EOF`
    that is only named inside a quoted --body or -m string for a real heredoc.
    So this walks the command the way the shell tokenises it: quoted strings,
    $( ... ) nesting (where quoting starts afresh, as in "$(cat <<'EOF' ...)"),
    arithmetic (( )) where << is a shift, and comments. Each pending heredoc's
    body is the lines after the next unquoted newline, up to the line equal to
    its delimiter (leading tabs stripped for <<-)."""
    stack = []  # open contexts: '"' string, '(' $( or subshell, '((' arithmetic
    pending = []
    i, n = 0, len(command)
    while i < n:
        c = command[i]
        if c == "\\":
            i += 2
            continue
        if stack and stack[-1] == '"':
            if c == '"':
                stack.pop()
            elif command.startswith("$(", i):
                stack.append("(")
                i += 1
            i += 1
            continue
        if c == "'":
            close = command.find("'", i + 1)
            i = n if close == -1 else close + 1
            continue
        if c == '"':
            stack.append('"')
        elif command.startswith("((", i):
            stack.append("((")
            i += 1
        elif c == "(":
            stack.append("(")
        elif c == ")" and stack:
            if stack.pop() == "((":
                i += 1  # the second ) of ))
        elif c == "#" and (i == 0 or command[i - 1] in " \t\n;&|("):
            close = command.find("\n", i)
            i = n if close == -1 else close
            continue
        elif command.startswith("<<<", i):
            i += 3
            continue
        elif command.startswith("<<", i) and "((" not in stack:
            i += 2
            strip_tabs = command.startswith("-", i)
            i += strip_tabs
            while i < n and command[i] in " \t":
                i += 1
            delimiter, quoted, i = heredoc_word(command, i)
            if delimiter:
                pending.append((delimiter, strip_tabs, quoted))
            continue
        elif c == "\n" and pending:
            i += 1
            for delimiter, strip_tabs, quoted in pending:
                body = []
                while i < n:
                    end = command.find("\n", i)
                    end = n if end == -1 else end
                    line = command[i:end]
                    i = end + 1
                    if (line.lstrip("\t") if strip_tabs else line) == delimiter:
                        break
                    body.append(line)
                # \\, \` and \$ are literal in an unquoted body.
                text = re.sub(r"\\[\\`$]", "", "\n".join(body))
                if not quoted and SUBSTITUTION_RE.search(text):
                    return True
            pending = []
            continue
        i += 1
    return False


# Claude Code cannot statically check a script handed to a shell as a string,
# so it stops for approval even in bypass mode ("This shell -c script runs rm
# and could not be checked": a sub-agent's echo-only `/bin/bash -c '…'`
# prompted the owner on 2026-10-09). The rule held only as prose until an
# agent ran `gtimeout 5400 bash -c 'until …; do sleep 20; done'` (#187).
# It judges the executable position, not the text: a grep, a quoted message
# or a data heredoc that names `bash -c` changes nothing and must pass.
STRING_EXECUTION = ("Blocked: a script string run through `sh -c`, `bash -c`, `zsh -c` or `eval`. "
                    "Claude Code cannot check such a script and asks the owner to approve it. "
                    "Write the script to the session scratchpad and run it with `bash <file>`.")
ASSIGNMENT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")
# Reserved words after which the next word is still a command.
SHELL_KEYWORDS = {"if", "then", "else", "elif", "while", "until", "do", "!", "{"}
# Programs that run the program named after them, with their flags that take
# a separate argument. timeout and gtimeout also take a duration first.
COMMAND_WRAPPERS = {
    "env": {"-u", "--unset", "-C", "--chdir", "-P"},
    "sudo": {"-u", "--user", "-g", "--group", "-h", "--host", "-p", "--prompt", "-C", "-D", "--chdir"},
    "doas": {"-u", "-C"},
    "nice": {"-n", "--adjustment"},
    "timeout": {"-k", "--kill-after", "-s", "--signal"},
    "gtimeout": {"-k", "--kill-after", "-s", "--signal"},
    "xargs": {"-I", "-J", "-L", "-n", "-P", "-s", "-E", "-R", "-S", "-d", "-a"},
    "nohup": set(), "command": set(), "exec": {"-a"}, "time": set(),
}
SHELL_C_FLAG_RE = re.compile(r"-[A-Za-z]*c[A-Za-z]*")  # -c, -lc, -ec


def strip_runner(tokens):
    """The command a leading runner executes, or None when there is no runner.

    check() judges the program at the head of a segment, so a runner in front
    hid it: `gtimeout 60 rm -r ~/Library/x` and `cpu-lock run … -- mkdir
    ~/Library/x` were both allowed, and cpu-lock is the wrapper the global
    policy requires for heavy work (measured 2026-10-31)."""
    if not tokens:
        return None
    head = os.path.basename(tokens[0])
    if head in ("timeout", "gtimeout", "nice"):
        i = 1
        while i < len(tokens) and tokens[i].startswith("-"):
            i += 1 + (tokens[i] in COMMAND_WRAPPERS[head])
        return tokens[i + (head != "nice"):]  # timeout's duration is not the program
    if head == "cpu-lock":
        return tokens[tokens.index("--") + 1:] if "--" in tokens else []
    return None


def runs_script_string(command, scripts=None):
    """True when `sh|bash|zsh -c` or `eval` is in an executable position.

    Walks the command the way the shell tokenises it: quoting, `\\` escapes,
    comments, `$(`, backticks and `(` (each opening a fresh command, including
    inside double quotes, where they still run), redirections and their
    operands, and the separators `;` `&` `|` and newline. Each word is judged
    by where it stands: after a separator, keyword, assignment, or wrapper
    such as `gtimeout 60` or `cpu-lock run … --`, it is the program; anything
    else is an argument.

    When `scripts` is a list, every file this command would execute as shell
    is appended to it: the file a shell is given (`bash file`, `zsh -li file`),
    the file `source` or `.` reads, and a program named by path (`./run.sh`),
    which script_verdict() opens only if it has a shell shebang."""
    command = strip_heredoc_bodies(command)
    mode, skip, wrapper, duration = "cmd", 0, None, False
    stack = []  # open '"', or '(' / '`' with the outer word and state saved
    word, started = [], False
    found = False  # a script string, when collecting scripts past it

    def hit():
        # Typed, the first hit decides. Collecting, keep walking: a file's
        # later lines can still run other scripts.
        nonlocal found, mode
        found, mode = True, "arg"
        return scripts is None

    def judge(text):
        nonlocal mode, skip, wrapper, duration
        if skip:
            skip -= 1
        elif mode == "dashdash":
            if text == "--":
                mode = "cmd"  # cpu-lock runs what follows its `--`
        elif mode == "shell":
            if text in ("-o", "+o", "-O", "+O"):
                skip = 1
            elif SHELL_C_FLAG_RE.fullmatch(text):
                return hit()
            elif not text.startswith(("-", "+")):
                mode = "arg"  # the script file: `bash script.sh`
                if scripts is not None:
                    scripts.append((text, "shell"))
        elif mode == "wrapper" and text.startswith("-"):
            skip = int(text in COMMAND_WRAPPERS[wrapper])
        elif mode == "wrapper" and duration:
            duration = False
        elif mode in ("cmd", "wrapper"):
            name = os.path.basename(text)
            if ASSIGNMENT_RE.match(text) or (mode == "cmd" and text in SHELL_KEYWORDS):
                pass
            elif name == "eval":
                return hit()
            elif name in COMMAND_WRAPPERS:
                mode, wrapper, duration = "wrapper", name, name in ("timeout", "gtimeout")
            elif name == "cpu-lock":
                mode = "dashdash"
            elif name in SHELL_INTERPRETERS or name in ("source", "."):
                mode = "shell"
            else:
                mode = "arg"
                if scripts is not None and "/" in text:
                    scripts.append((text, "program"))
        return False

    def finish():
        nonlocal word, started
        text, had = "".join(word), started or bool(word)
        word, started = [], False
        return had and judge(text)

    def open_command(context):
        nonlocal mode, skip, wrapper, duration, word, started
        stack.append((context, word, started, mode, skip, wrapper, duration))
        word, started = [], False
        mode, skip, wrapper, duration = "cmd", 0, None, False

    def close_command():
        nonlocal mode, skip, wrapper, duration, word, started
        hit = finish()
        _, word, started, mode, skip, wrapper, duration = stack.pop()
        return hit

    i, n = 0, len(command)
    while i < n:
        c = command[i]
        if stack and stack[-1][0] == '"':
            if c == "\\":
                word.append(command[i + 1:i + 2])
                i += 2
                continue
            if c == '"':
                stack.pop()
            elif command.startswith("$((", i):
                close = command.find("))", i)
                i = n if close == -1 else close + 2
                continue
            elif command.startswith("$(", i):
                open_command("(")
                i += 1
            elif c == "`":
                open_command("`")
            else:
                word.append(c)
            i += 1
            continue
        if c == "\\":
            if command[i + 1:i + 2] != "\n":
                word.append(command[i + 1:i + 2])
            i += 2
            continue
        if c == "'":
            close = command.find("'", i + 1)
            close = n if close == -1 else close
            word.append(command[i + 1:close])
            started, i = True, close + 1
            continue
        if c == '"':
            stack.append(('"',))
            started = True
        elif c in " \t":
            if finish():
                return True
        elif c == "#" and not word and not started:
            close = command.find("\n", i)
            i = n if close == -1 else close
            continue
        elif command.startswith("$((", i):
            close = command.find("))", i)
            i = n if close == -1 else close + 2
            continue
        elif command.startswith("$(", i):
            open_command("(")
            i += 1
        elif c == "`":
            if stack and stack[-1][0] == "`":
                if close_command():
                    return True
            else:
                open_command("`")
        elif c == "(":
            if finish():
                return True
            open_command("(")
        elif c == ")":
            if stack and stack[-1][0] == "(":
                if close_command():
                    return True
            elif finish():
                return True
        elif c in "<>" or (c == "&" and command.startswith(">", i + 1)):
            if finish():
                return True
            while i < n and command[i] in "<>&|":
                i += 1
            if command[i:i + 1] != "(":  # <(…) is a command, not an operand
                skip += 1
            continue
        elif c in ";&|\n":
            if finish():
                return True
            mode, skip, wrapper, duration = "cmd", 0, None, False
        else:
            word.append(c)
        i += 1
    return finish() or found


def check_command(command, typed=True):
    """Rules that need the whole command, heredoc bodies included.

    split_segments() drops a heredoc fed to an interpreter as data, which is
    right for its other rules and wrong for these: `python3 - <<PY` with a
    requests.post() to the GitHub API is a write that never appears as a
    segment of its own, and an unquoted heredoc runs the substitutions in its
    body whatever program reads it.

    The first two rules are about the typed command itself: a heredoc an agent
    meant to be literal, and a script string Claude Code cannot check and so
    stops to ask the owner about. Inside a script file (`typed=False`) neither
    applies; a file is the form both denials ask for, and a script's own
    heredocs expand on purpose."""
    if typed and unquoted_heredoc_substitution(command):
        return HEREDOC_SUBSTITUTION
    if typed and runs_script_string(command):
        return STRING_EXECUTION
    if not GITHUB_API_RE.search(command) or not SCRIPT_WRITE_RE.search(command):
        return None
    for segment in re.split(r"&&|\|\||[;&|\n]", command):
        try:
            words = shlex.split(segment)
        except ValueError:
            words = segment.split()
        if any(INTERPRETERS_RE.fullmatch(os.path.basename(w)) for w in words[:3]):
            return RAW_GITHUB_WRITE
    return None


def check(segment):
    raw = segment.strip()
    try:
        tokens = shlex.split(raw)
    except ValueError:
        tokens = raw.split()
    if not tokens:
        return None

    # Peel wrappers, runners and leading VAR=value assignments. The biometric
    # rule is judged at every layer, so a runner cannot hide an `env -i`.
    while tokens:
        if reenables_app_integration(tokens):
            return ("Blocked: setting, unsetting or dropping OP_BIOMETRIC_UNLOCK_ENABLED (including "
                    "`env -i`). Agent commands run with it false so nothing they run can reach the "
                    "1Password desktop app or raise a Touch ID prompt. The steps that need the owner "
                    "have declared commands that ask deliberately; see the credentials rules.")
        head = os.path.basename(tokens[0])
        inner = strip_runner(tokens)
        if inner is not None:
            tokens = inner
            continue
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

    if raw_github_write(prog, args, raw):
        return RAW_GITHUB_WRITE

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
    if installs_python_packages_outside_uv(prog, args, raw):
        return (f"Blocked: `{raw.strip()}`\n\nuv owns Python on this Mac: never install into an "
                "interpreter or pass --break-system-packages. Use `uv run --with PKG`, PEP 723 "
                "script metadata with `uv run`, or a project venv (`uv venv`, `uv pip install`, "
                "`uv sync`).")
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


# The guard judged only the typed command, so a script file it ran was never
# read: on 2026-10-30 an agent's `bash probe.sh` created and filled a
# directory under ~/Library/Caches with `DST="$HOME/Library/…"; mkdir -p
# "$DST"; cp -R … "$DST/"`, the very writes the guard denies when typed, and
# the global policy tells agents to put multi-step work in such files. A file
# a command executes as shell is now judged by the same rules, line by line,
# with its simple NAME=value assignments expanded first, and so is any file it
# runs in turn. Reading a file changes nothing, so a missing or unreadable
# file, or a path built from a variable the guard cannot resolve, is skipped
# rather than denied.
#
# A script git tracks, unchanged from its index entry, is the repository's
# own mechanism and passes, as `just` recipes do: another repository's
# Connect loader clears inherited OP_* variables before loading its own, and
# nix-config's setup scripts do what only the owner's setup may. Measured on
# 2026-10-31 over 3,359 scripts on this Mac (repositories' tracked scripts,
# agents' scratchpads, Codex run scripts): 15 s in all, none over 0.5 s.
SHELL_SHEBANG_RE = re.compile(rb"#![ \t]*/\S*/(?:env[ \t]+(?:-\S+[ \t]+)*)?(?:ba|z|da|k)?sh\b")
SCRIPT_MAX_BYTES = 1 << 20
SCRIPT_MAX_DEPTH = 4
ASSIGNMENT_LINE_RE = re.compile(
    r"^\s*(?:(?:export|local|readonly|declare|typeset)\s+(?:-\S+\s+)*)?"
    r"([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
VARIABLE_RE = re.compile(r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))")


def expand_assignments(text):
    """Substitute each simple `NAME=value` into the lines after it.

    Only a value that is one shell word after quote removal is recorded. Any
    `$NAME` inside it is expanded from earlier assignments; anything the guard
    cannot know (`$(...)`, an unassigned variable) stays as written."""
    values = {}
    out = []

    def substitute(match):
        name = match.group(1) or match.group(2)
        return values.get(name, match.group(0))

    for line in text.split("\n"):
        if values and "$" in line:
            line = VARIABLE_RE.sub(substitute, line)
        match = ASSIGNMENT_LINE_RE.match(line)
        if match:
            try:
                words = shlex.split(match.group(2))
            except ValueError:
                words = []
            if len(words) == 1:
                values[match.group(1)] = words[0]
        out.append(line)
    return "\n".join(out)


def repository_script(full):
    """True when git tracks this file and its contents match the index.

    Inherited GIT_DIR / GIT_INDEX_FILE / GIT_WORK_TREE (set inside git hooks)
    would point git at another repository's index, so git finds the file's
    own repository from its directory instead."""
    directory = os.path.dirname(full)
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    try:
        tracked = subprocess.run(["git", "-C", directory, "ls-files", "--error-unmatch", "--", full],
                                 capture_output=True, timeout=5, env=env)
        if tracked.returncode != 0:
            return False
        unchanged = subprocess.run(["git", "-C", directory, "diff", "--quiet", "--", full],
                                   capture_output=True, timeout=5, env=env)
        return unchanged.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def script_verdict(path, kind, cwd, depth, seen):
    """The denial reason for a file a command runs as shell, or None."""
    if depth > SCRIPT_MAX_DEPTH or "$" in path or "`" in path:
        return None
    full = os.path.expanduser(path)
    if not os.path.isabs(full):
        if not cwd:
            return None
        full = os.path.join(cwd, full)
    full = os.path.realpath(full)
    if full in seen or not os.path.isfile(full):
        return None
    seen.add(full)
    try:
        with open(full, "rb") as handle:
            data = handle.read(128)
            if kind == "program" and not SHELL_SHEBANG_RE.match(data):
                return None  # a binary or another language's script
            data += handle.read(SCRIPT_MAX_BYTES + 1 - len(data))
    except OSError:
        return None
    if len(data) > SCRIPT_MAX_BYTES or repository_script(full):
        return None
    reason = command_verdict(expand_assignments(data.decode("utf-8", "replace")),
                             cwd, depth + 1, seen, typed=False)
    return reason and f"Blocked: the script {path} would run this.\n\n{reason}"


def command_verdict(command, cwd=None, depth=0, seen=None, typed=True):
    """The denial reason for a typed command or a script's text, or None."""
    seen = set() if seen is None else seen
    reason = check_command(command, typed)
    if reason:
        return reason
    for segment in split_segments(command):
        reason = check(segment)
        if reason:
            return reason
    scripts = []
    runs_script_string(command, scripts)
    for path, kind in scripts:
        reason = script_verdict(path, kind, cwd, depth, seen)
        if reason:
            return reason
    return None


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    command = (payload.get("tool_input") or {}).get("command") or ""
    if not command:
        sys.exit(0)

    reason = command_verdict(command, payload.get("cwd"))
    if reason:
        deny(reason)

    sys.exit(0)


if __name__ == "__main__":
    main()
