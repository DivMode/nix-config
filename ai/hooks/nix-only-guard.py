#!/usr/bin/env python3
"""PreToolUse guard: block machine mutation that bypasses Nix.

Reads the hook payload on stdin, inspects the Bash command, and denies any
segment that changes macOS system/application state or installs software
outside the Nix/nix-darwin flow. Read-only inspection is always allowed.

The rule this enforces: desired state is declared in the Nix configuration and
applied by `darwin-rebuild switch`. Nothing else may touch the machine.
"""

import fnmatch
import collections
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


# The supervisor forwards a denial in one atomic pipe write and drops one
# larger than PIPE_BUF (supervisor.py, emit(); 512 bytes on macOS), and a
# dropped denial lets the command run. The build contract showed it on
# 2026-11-11: a 560-byte reason for `kill -TERM -- "-$group"` was never
# delivered. A long reason therefore loses its middle: the start names the
# command, the end says what to do instead.
DENIAL_LIMIT = 500
DENIAL_HEAD = 120


def denial(reason):
    """The hook output for a denial, as the supervisor re-serialises it."""
    def encoded(text):
        return json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": text,
            }
        }, separators=(",", ":"))

    output, cut = encoded(reason), 0
    while len(output) > DENIAL_LIMIT and DENIAL_HEAD + cut < len(reason):
        cut += 20
        output = encoded(reason[:DENIAL_HEAD] + " [...] " + reason[DENIAL_HEAD + cut:])
    if len(output) > DENIAL_LIMIT:
        # The start alone is too long once escaped (non-ASCII text costs six
        # bytes a character). A denial with a bare reason still denies.
        output = encoded("Blocked by the machine's command guard (the reason was too long to send).")
    return output


def deny(reason):
    print(denial(reason))
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
    """True when an unquoted heredoc's body contains a backtick or `$(`."""
    return any(SUBSTITUTION_RE.search(body) for body in unquoted_heredoc_bodies(command))


def substitutions(body):
    """The command text inside each `$(...)` and backtick pair of a heredoc
    body. Quotes do not quote there, so the body is not walked as shell."""
    i, n = 0, len(body)
    while i < n:
        if body.startswith("$((", i):
            close = body.find("))", i)
            i = n if close == -1 else close + 2
        elif body.startswith("$(", i):
            depth, j = 1, i + 2
            while j < n and depth:
                depth += (body[j] == "(") - (body[j] == ")")
                j += 1
            yield body[i + 2:j - 1 if depth == 0 else n]
            i = j
        elif body[i] == "`":
            close = body.find("`", i + 1)
            close = n if close == -1 else close
            yield body[i + 1:close]
            i = close + 1
        else:
            i += 1


def unquoted_heredoc_bodies(command):
    """The body of each unquoted heredoc, where the shell runs substitutions.

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
                if not quoted:
                    yield re.sub(r"\\[\\`$]", "", "\n".join(body))
            pending = []
            continue
        i += 1


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
# The two names of the memory queue's runner (cpu-lock is an alias for
# `membrake exec`).
QUEUE_RUNNERS = {"cpu-lock", "membrake"}
SHELL_C_FLAG_RE = re.compile(r"-[A-Za-z]*c[A-Za-z]*")  # -c, -lc, -ec


def strip_runner(tokens):
    """The command a leading runner executes, or None when there is no runner.

    check() judges the program at the head of a segment, so a runner in front
    hid it: `gtimeout 60 rm -r ~/Library/x` and `cpu-lock run … -- mkdir
    ~/Library/x` were both allowed, and cpu-lock is the wrapper the global
    policy requires for heavy work (measured 2026-10-31). `membrake exec … --
    cmd` is the same runner, and cpu-lock is now an alias for it."""
    if not tokens:
        return None
    head = os.path.basename(tokens[0])
    if head in ("timeout", "gtimeout", "nice"):
        i = 1
        while i < len(tokens) and tokens[i].startswith("-"):
            i += 1 + (tokens[i] in COMMAND_WRAPPERS[head])
        return tokens[i + (head != "nice"):]  # timeout's duration is not the program
    if head == "cpu-lock" or (head == "membrake" and tokens[1:2] == ["exec"]):
        return tokens[tokens.index("--") + 1:] if "--" in tokens else []
    return None


def peel(tokens):
    """One layer off a command: (what it runs, whether the layer was the memory
    queue), or None when `tokens` already start with the program.

    A layer is a runner (see strip_runner), a wrapper such as `sudo` or `env`
    with its own flags (`env -u NAME`, `env -i`, `sudo -E` are not the program;
    nor is the argument of the flags that take one), or a leading VAR=value."""
    head = os.path.basename(tokens[0])
    inner = strip_runner(tokens)
    if inner is not None:
        return inner, head in QUEUE_RUNNERS
    if head in WRAPPERS or ASSIGNMENT_RE.match(tokens[0]):
        tokens = tokens[1:]
        while tokens and tokens[0].startswith("-"):
            flag = tokens.pop(0)
            if flag in {"-u", "--unset", "-C", "--chdir", "-S", "--split-string",
                        "-p", "--prompt", "-g", "--group", "-h", "--host"} and tokens:
                tokens.pop(0)
        return tokens, False
    return None


# Script strings inside script strings (`eval eval …`, `sh -c "sh -c …"`) are
# walked to this depth. Deeper text is not judged in part: the command is
# refused (see command_verdict), because a hook that crashes lets it run.
STRING_MAX_NESTING = 8
TOO_DEEP = ("Blocked: this command nests script strings (`eval`, `sh -c`) too deeply for the "
            "command guard to read. Write the commands out, or put them in a script file.")


class TooDeep(Exception):
    """Script strings nested deeper than STRING_MAX_NESTING."""


def runs_script_string(command, scripts=None, commands=None, nesting=0):
    """True when `sh|bash|zsh -c` or `eval` is in an executable position.

    Walks the command the way the shell tokenises it: quoting, `\\` escapes,
    comments, `$(`, backticks and `(` (each opening a fresh command, including
    inside double quotes, where they still run), redirections and their
    operands, and the separators `;` `&` `|` and newline. Each word is judged
    by where it stands: after a separator, keyword, assignment, or wrapper
    such as `gtimeout 60` or `membrake exec … --`, it is the program; anything
    else is an argument.

    When `scripts` is a list, every file this command would execute as shell
    is appended to it: the file a shell is given (`bash file`, `zsh -li file`),
    the file `source` or `.` reads, and a program named by path (`./run.sh`),
    which script_verdict() opens only if it has a shell shebang.

    When `commands` is a list, every other simple command is appended to it
    as {"argv": [program name, argument, ...], "lookup": bool, "direct":
    bool}, wherever it stands (after `do`, inside `$(...)`, behind `xargs`).
    `lookup` is true when its targets come from a process search: a
    PROCESS_LOOKUPS program earlier in the same pipeline, or inside a
    substitution among its arguments. `direct` is true when the program is
    the bare word the shell resolves itself, with no path and no wrapper or
    runner in front. An argument that is only a substitution leaves no word."""
    if nesting > STRING_MAX_NESTING:
        raise TooDeep
    command = strip_heredoc_bodies(command)
    mode, skip, wrapper, duration = "cmd", 0, None, False
    stack = []  # open '"', or '(' / '`' with the outer word and state saved
    word, started = [], False
    found = False  # a script string, when collecting scripts past it
    current, fed = None, False  # the command being collected; a lookup feeds this pipeline
    wrapped = False  # a wrapper or runner stands in front of the program
    code, code_words = None, []  # shell text follows: "one" word (`sh -c`) or "all" (`eval`)
    cases = 0  # `case` statements open in this context, whose patterns end in `)`

    def flush():
        # `eval`'s arguments are one command once joined.
        nonlocal code_words
        if code_words:
            words, code_words = code_words, []
            runs_script_string(" ".join(words), scripts, commands, nesting + 1)

    def restart():
        # A new command begins.
        nonlocal mode, skip, wrapper, duration, current, wrapped, code
        flush()
        mode, skip, wrapper, duration = "cmd", 0, None, False
        current, wrapped, code = None, False, None

    def begin(name, direct):
        nonlocal current, fed
        current = {"argv": [name], "lookup": fed, "direct": direct}
        if commands is not None:
            commands.append(current)
        if name in PROCESS_LOOKUPS:
            fed = True
            for entry in stack:
                if len(entry) > 1 and entry[7] is not None:
                    entry[7]["lookup"] = True

    def hit(follows):
        # Typed, the first hit decides. Collecting, keep walking: a file's
        # later lines can still run other scripts, and the script string
        # itself is walked for the commands it holds.
        nonlocal found, mode, code
        found, mode, code = True, "arg", follows
        return scripts is None

    def judge(text, quoted=False):
        nonlocal mode, skip, wrapper, duration, current, wrapped, code, cases
        if skip:
            skip -= 1
        elif mode == "dashdash":
            if text == "--":
                mode = "cmd"  # cpu-lock and membrake exec run what follows their `--`
        elif mode == "shell":
            if text in ("-o", "+o", "-O", "+O"):
                skip = 1
            elif SHELL_C_FLAG_RE.fullmatch(text):
                return hit("one")
            elif not text.startswith(("-", "+")):
                mode = "arg"  # the script file: `bash script.sh`
                if scripts is not None:
                    scripts.append((text, "shell"))
        elif mode == "wrapper" and text.startswith("-"):
            if wrapper == "command" and text in ("-v", "-V"):
                mode = "arg"  # `command -v NAME` asks what NAME is; it runs nothing
            else:
                skip = int(text in COMMAND_WRAPPERS[wrapper])
        elif mode == "wrapper" and duration:
            duration = False
        elif mode in ("cmd", "wrapper"):
            name = os.path.basename(text)
            if ASSIGNMENT_RE.match(text) or (mode == "cmd" and text in SHELL_KEYWORDS):
                pass
            elif mode == "cmd" and text == "esac" and not quoted:
                cases = max(0, cases - 1)
            elif name == "eval":
                return hit("all")
            elif name in COMMAND_WRAPPERS:
                mode, wrapper, duration = "wrapper", name, name in ("timeout", "gtimeout")
                wrapped = True
            elif name in QUEUE_RUNNERS:
                mode, wrapped = "dashdash", True
            elif name in SHELL_INTERPRETERS or name in ("source", "."):
                mode = "shell"
            else:
                mode = "arg"
                if scripts is not None and "/" in text:
                    scripts.append((text, "program"))
                begin(name, not wrapped and text == name)
                if text == "case":
                    cases += 1
        elif mode == "arg" and code == "one":
            # `sh -c -- TEXT`: the option terminator is not the text.
            if text != "--":
                code = None
                if scripts is not None:
                    runs_script_string(text, scripts, commands, nesting + 1)
        elif mode == "arg" and code == "all":
            # `eval -- TEXT`: likewise.
            if code_words or text != "--":
                code_words.append(text)
        elif mode == "arg" and text == "{" and not quoted:
            # `name() { command` and `function name { command`: the brace
            # opens a body, so the next word is a program again. A quoted
            # brace is an argument.
            mode, current, wrapped = "cmd", None, False
        elif mode == "arg" and current is not None:
            current["argv"].append(text)
        return False

    def finish():
        nonlocal word, started
        text, had, quoted = "".join(word), started or bool(word), started
        word, started = [], False
        return had and judge(text, quoted)

    def in_case_pattern(after_blank=False):
        # The word before this `)` is a `case` pattern: at a command's start
        # inside a `case`, or among the words of `case WORD in`. With
        # `after_blank` (a top-level `)` that follows a blank, never one that
        # closes a substitution) also a single word a blank already ended and
        # so took for a command name: `'esac' )`.
        return cases and (mode == "cmd" or (current is not None and (
            (current["argv"][0] == "case" and "in" in current["argv"])
            or (after_blank and mode == "arg" and len(current["argv"]) == 1))))

    def drop_pattern():
        # A pattern ended by a blank was recorded as a command; it is not one.
        if (current is not None and len(current["argv"]) == 1 and commands
                and commands[-1] is current):
            commands.pop()

    def open_command(context, piped=False):
        nonlocal mode, skip, wrapper, duration, word, started, current, fed, wrapped, code, cases
        stack.append((context, word, started, mode, skip, wrapper, duration, current, fed, wrapped,
                      code, cases, code_words[:]))
        del code_words[:]
        word, started = [], False
        mode, skip, wrapper, duration = "cmd", 0, None, False
        current, wrapped, code, cases = None, False, None, 0
        # A pipeline's lookup feeds a subshell (`pgrep … | (xargs kill)`),
        # not a substitution, which reads nothing from the pipe.
        fed = fed and piped

    def close_command():
        nonlocal mode, skip, wrapper, duration, word, started, current, fed, wrapped, code, cases
        hit = finish()
        flush()
        (_, word, started, mode, skip, wrapper, duration, current, fed, wrapped,
         code, cases, saved_words) = stack.pop()
        code_words.extend(saved_words)
        if in_case_pattern():
            restart()  # `case WORD in (PATTERN) command`: the group was the pattern
        elif skip or mode == "arg":
            # A substitution that adds no text is still the word it stands
            # for: a redirection's operand (`>$(mktemp) NAME` must not take
            # NAME for the operand) or an argument.
            started = True
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
                # An escaped character quotes the word, as `'…'` does: `\esac`
                # and `\{` are not reserved words.
                word.append(command[i + 1:i + 2])
                started = True
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
            open_command("(", piped=True)
        elif c == ")":
            if mode == "cmd" and "".join(word) == "esac" and not started:
                # `$(case … esac)`: the word ends the case, and this `)` is
                # the substitution's.
                if finish():
                    return True
            if in_case_pattern(after_blank=not word and not started and command[i - 1:i] in (" ", "\t")):
                # `PATTERN)`: what follows is the arm's command, also inside
                # a substitution, whose own `)` this is not.
                word, started = [], False
                drop_pattern()
                restart()
            elif stack and stack[-1][0] == "(":
                if close_command():
                    return True
            elif finish():
                return True
            else:
                restart()  # a `)` that closes nothing: read on as a command
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
            restart()
            # `a | b` and `a |& b` keep the pipeline; `||` and the rest end it.
            before, after = command[i - 1:i], command[i + 1:i + 2]
            if not ((c == "|" and "|" not in (before, after)) or (c == "&" and before == "|")):
                fed = False
        else:
            word.append(c)
        i += 1
    done = finish()
    flush()
    return done or found


# No agent command may signal what it did not start (issue #270). On
# 2026-11-11 a script written by a delegated worker walked the process table,
# collected 446 process groups, the first being group 1, and ran
# `kill -TERM -- -<group>` for each: every application the owner had open was
# terminated. This guard read only the typed command (`bash interrupt.sh`);
# the script it ran was tracked and edited, and nothing judged its lines for
# signalling.
#
# Three things are refused, wherever they stand in a typed command or in a
# script it runs (the walker above finds the program after `do`, inside
# `$(...)`, behind `xargs` or `command`):
#   - `kill` aimed at a process group (any target that starts with `-`, which
#     includes `-1`, every process the user owns);
#   - `pkill`, and `killall` beyond the interface agents: they choose targets
#     by name or pattern;
#   - `kill` fed by `pgrep` or `pidof` (`pgrep … | xargs kill`,
#     `kill $(pgrep …)`), the same thing in two steps;
#   - `kill` reached any way but as the bare word: by path (`/bin/kill`) or
#     behind `xargs`, `command`, `builtin`, `env`, `sudo`, `exec` and the
#     like. Those skip the shell guard's function, and a target held in a
#     variable or arriving on a pipe cannot be read here, so nothing would
#     check it. The bare word is all an agent needs.
# Listing (`kill -l`) and the probe signal 0 deliver nothing and pass. `kill 0`
# passes too: it reaches only the caller's own group.
#
# Not read: a command held in a string (`trap 'kill …' EXIT`) or built from a
# variable. There the shell guard is what refuses a group.
#
# The limit: this reads shell text. A program that makes the system call
# itself is not seen, and the shell guard (../shell-guard/kill-guard.sh) is
# what refuses a group at the moment of the call. Agents and the owner's
# applications run as one user, so the system delivers any signal that is
# sent.
PROCESS_LOOKUPS = {"pgrep", "pidof"}
SIGNAL_RULE = (" Signal only process ids this command started and recorded (`cmd & pid=$!`, then "
               "`kill $pid`). Never a process group, `-1`, or a target found by name, pattern or a "
               "process search: on 2026-11-11 that terminated every application the owner had "
               "open (nix-config issue 270).")


def walk_script(text, scripts, commands):
    """Collect, from a script's text, the files it runs and its simple
    commands, including those inside the substitutions of its unquoted
    heredocs: a script's heredocs expand on purpose (see check_command), so
    what they run is read rather than refused."""
    runs_script_string(text, scripts, commands)
    for body in unquoted_heredoc_bodies(text):
        for inner in substitutions(body):
            runs_script_string(inner, scripts, commands)


def kill_targets(args):
    """The targets of `kill ARGS`, or None when it delivers nothing (a
    listing, or the probe signal 0).

    bash keeps reading options after the first signal: `-s 0 -s TERM` sends
    TERM, and in bash 3.2 so does `-s 0 -15` (builtins/kill.def: `-s` and
    `-n` do not mark the signal as seen). A probe therefore counts only when
    nothing between the option and `--` starts with `-`; a group is probed
    as `kill -0 -- -GROUP`. Otherwise every argument is read as a target, and
    a target that starts with `-` is refused."""
    first, quiet = 0, False
    if args and args[0].startswith("-") and args[0] != "--":
        if args[0] in ("-l", "-L"):
            return None
        first = 1
        quiet = args[0] == "-0"
        if args[0] in ("-s", "-n"):
            quiet = args[1:2] == ["0"]
            first = 2
    rest = args[first:]
    before = rest[:rest.index("--")] if "--" in rest else rest
    if quiet and not any(target.startswith("-") for target in before):
        return None
    return [target for target in rest if target != "--"]


def signalling(commands):
    """(the command as written, why it is refused) for each collected command
    that signals a process group or chooses its targets by name or pattern."""
    for record in commands:
        argv = record["argv"]
        if argv[0] == "builtin":
            argv = argv[2:] if argv[1:2] == ["--"] else argv[1:]
        if not argv:
            continue
        if argv[0] == "trap":
            # `trap 'COMMANDS' SIGNAL...`: the handler is shell text, and the
            # usual place for cleanup.
            handler = next((arg for arg in argv[1:] if not arg.startswith("-")), None)
            if handler:
                inner = []
                runs_script_string(handler, [], inner, 1)
                yield from signalling(inner)
            continue
        prog, args, shown = argv[0], argv[1:], " ".join(argv)
        if prog == "pkill" or (prog == "killall" and not restarts_only_ui_agents(args)):
            yield shown, f"`{prog}` chooses its targets by name or pattern."
        elif prog == "kill":
            targets = kill_targets(args)
            if targets is None:
                continue
            if any("".join(target.split()).startswith("-") for target in targets):
                yield shown, "It signals a process group, or every process the user owns."
            elif record["lookup"]:
                yield shown, "Its targets come from a search of the process table."
            elif not record["direct"] or argv is not record["argv"]:
                yield shown, ("It reaches `kill` by a path or behind a wrapper, which skips the "
                              "shell guard. Call plain `kill`.")


def signal_verdict(commands):
    for shown, why in signalling(commands):
        return f"Blocked: `{shown}`\n\n{why}{SIGNAL_RULE}"
    return None


# The same rule at the moment such code is written (both clients offer a hook
# on file edits: Claude Code's Edit, MultiEdit and Write, Codex's apply_patch,
# whose `tool_input.command` is the patch text). It judges the TEXT an edit
# writes, each replacement against the text it replaces, and a whole-file
# write against the file as it is. It does not rebuild the file the edit
# produces: rounds 1 to 7 of the review of #271 showed that matching every
# rule apply_patch and the edit tools use (anchors, blanks, line ends, end of
# file) is a parser of its own that keeps being wrong. So an edit whose
# meaning depends on the text around it (changing `12345` into `-1` inside
# `kill -- 12345`) is not seen here. It is seen when the script runs: the
# command hook reads an edited or untracked script it is asked to run, and the
# shell guard refuses a foreign group at the call.
#   - A shell file (by extension, by a startup file's name, by a shell shebang
#     in the file now, or in any text the edit writes) is read with the rule
#     above. Writing such a command into a string or a heredoc of one is
#     refused too: the text is judged without knowing where it lands.
#   - A source file in another language is searched, by a heuristic, for a
#     string literal that starts with a pattern-based terminator
#     (`execSync("pkill -f …")`, `["killall", name]`): it runs through `sh`,
#     which loads no shell guard, so nothing else would stop it.
# Not judged: prose, Nix modules (declaring an application restart there is
# what this guard tells agents to do), a shell file with neither a known name
# nor a shebang, and signals another language sends by system call, where a
# group the code started itself cannot be told from one it looked up.
EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "apply_patch"}
# The signal guard's own sources and tests necessarily contain the code they
# refuse. Relative to the root of the machine's nix-config checkout or one of
# its linked worktrees, which main() is told with `--nix-config`; the same
# path anywhere else is judged (see guard_source).
SIGNAL_GUARD_SOURCES = ("ai/shell-guard/kill-guard.sh", "ai/shell-guard/kill-guard-test.sh",
                        "ai/hooks/nix-only-guard.py", "ai/hooks/nix-only-guard-test.py")
SHELL_FILE_RE = re.compile(r"\.(?:sh|bash|zsh|ksh|command)$")
SHELL_STARTUP_FILES = {".zshenv", ".zshrc", ".zprofile", ".zlogin", ".bashrc", ".bash_profile",
                       ".profile", ".envrc"}
SOURCE_FILE_RE = re.compile(r"\.(?:py|js|mjs|cjs|ts|mts|cts|tsx|jsx|rb|pl|php|lua|go|rs|swift|java|kt)$"
                            r"|(?:^|/)package\.json$")
TERMINATOR_LITERAL_RE = re.compile(
    r"""["'`](?:/usr/bin/)?(?:pkill|(?P<by_name>killall))(?=["'`\s])""")
# A whole-line comment, by the file's language: `#` in Python, Ruby and Perl,
# `//` in the C family, either in PHP. Nothing else is skipped (a block
# comment's ` * ` line, Lua's `--`), because the same start is code elsewhere
# (`* p = …` in Go, `-- n` in JavaScript); such a line is refused if it names
# a terminator, which errs the safe way.
HASH_COMMENT_FILE_RE = re.compile(r"\.(?:py|rb|pl)$")
SLASH_COMMENT_FILE_RE = re.compile(r"\.(?:js|mjs|cjs|ts|mts|cts|tsx|jsx|go|rs|swift|java|kt)$|(?:^|/)package\.json$")


def comment_line_re(path):
    if HASH_COMMENT_FILE_RE.search(path):
        return re.compile(r"\s*#")
    if SLASH_COMMENT_FILE_RE.search(path):
        return re.compile(r"\s*//")
    if path.endswith(".php"):
        return re.compile(r"\s*(?:#|//)")
    return re.compile(r"(?!)")


PATCH_FILE_RE = re.compile(r"\*\*\* (Add|Update) File: (.+)")
PATCH_MOVE_RE = re.compile(r"\*\*\* Move to: (.+)")
# The most text the check reads from one file or one replacement. A shell or
# source file's edit that writes more is refused rather than judged in part;
# an existing file larger than this counts as holding nothing.
EDIT_MAX_BYTES = 4 << 20


def read_text(full):
    """The file's text, or "" when it cannot be read or is too large."""
    try:
        with open(full, "rb") as handle:
            data = handle.read(EDIT_MAX_BYTES + 1)
    except OSError:
        return ""
    return "" if len(data) > EDIT_MAX_BYTES else data.decode("utf-8", "replace")


def edit_changes(tool_input):
    """(path read, path written, [(old text or None, new text)]) for each file
    an edit call writes. None stands for the whole file as it is: a Write,
    or a patch that adds a file."""
    path = tool_input.get("file_path")
    if isinstance(path, str):
        if isinstance(tool_input.get("content"), str):
            return [(path, path, [(None, tool_input["content"])])]
        edits = tool_input.get("edits")
        edits = [e for e in edits if isinstance(e, dict)] if isinstance(edits, list) else [tool_input]
        return [(path, path, [(e["old_string"], e["new_string"]) for e in edits
                              if isinstance(e.get("old_string"), str) and isinstance(e.get("new_string"), str)])]
    patch = tool_input.get("command")
    files = []
    for section in re.split(r"(?m)^(?=\*\*\* (?:Add|Update|Delete) File: )", patch) if isinstance(patch, str) else []:
        header = PATCH_FILE_RE.match(section)
        if not header:
            continue
        kind, path = header.group(1), header.group(2).strip()
        destination, changes = path, []
        for hunk in re.split(r"(?m)^@@.*$", section[header.end():]):
            old, new = [], []
            for line in hunk.split("\n"):
                move = PATCH_MOVE_RE.match(line)
                if move:
                    destination = move.group(1).strip()
                elif line.startswith("*** "):
                    continue
                elif line.startswith("+"):
                    new.append(line[1:])
                elif line.startswith("-"):
                    old.append(line[1:])
                elif line.startswith(" "):
                    old.append(line[1:])
                    new.append(line[1:])
            if old or new:
                changes.append((None if kind == "Add" else "\n".join(old), "\n".join(new)))
        files.append((path, destination, changes))
    return files


def terminator_literals(text, path):
    """Each string literal in another language's source that shells out to a
    pattern-based terminator. A heuristic, not a parser: it reads one line at
    a time, skips whole-line comments, and lets the name-based one through
    only when the rest of its call, on that line, names interface agents
    alone. It errs towards refusing: a string that merely holds such a
    command as data is refused too, and can be assembled from two parts."""
    found, comment = [], comment_line_re(path)
    for line in text.split("\n"):
        if comment.match(line):
            continue
        for match in TERMINATOR_LITERAL_RE.finditer(line):
            rest = re.split(r"[)\]]", line[match.end():], maxsplit=1)[0]
            words = re.findall(r"-?[A-Za-z0-9_.$-]+", rest)
            if match.group("by_name") is None or not restarts_only_ui_agents(words):
                found.append(line.strip())
    return found


def signalling_text(text, shell, path=""):
    """What `text` holds that the signalling rule refuses, one entry per
    occurrence."""
    if not shell:
        return terminator_literals(text, path)
    commands = []
    walk_script(text, [], commands)
    return [shown for shown, _why in signalling(commands)]


def guard_source(full, checkout):
    """True when `full` is one of SIGNAL_GUARD_SOURCES in the machine's
    nix-config repository: the checkout `--nix-config` names, or a linked
    worktree whose git directory is that checkout's. The file is resolved
    first, so a link from there to a file elsewhere is not one."""
    full = os.path.realpath(full)
    relative = next((source for source in SIGNAL_GUARD_SOURCES if full.endswith("/" + source)), None)
    if not checkout or relative is None:
        return False
    root = full[:-len(relative) - 1]
    if root == os.path.realpath(checkout):
        return True
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    try:
        found = subprocess.run(["git", "-C", root, "rev-parse", "--path-format=absolute",
                                "--git-common-dir", "--show-toplevel"],
                               capture_output=True, text=True, timeout=5, env=env)
    except (OSError, subprocess.TimeoutExpired):
        return False
    lines = found.stdout.split("\n")
    return (found.returncode == 0 and len(lines) >= 2
            and os.path.realpath(lines[0]) == os.path.realpath(os.path.join(checkout, ".git"))
            and os.path.realpath(lines[1]) == root)


def edit_verdict(tool_input, cwd=None, checkout=None):
    """The denial reason for a file edit that introduces signalling code."""
    try:
        return read_edit(tool_input, cwd, checkout)
    except (TooDeep, RecursionError):
        return TOO_DEEP


def read_edit(tool_input, cwd, checkout):
    """edit_verdict()'s work."""
    def full_path(path):
        full = os.path.expanduser(path)
        return full if os.path.isabs(full) else os.path.join(cwd or "", full)

    def shebang(text):
        return bool(SHELL_SHEBANG_RE.match(text[:128].encode("utf-8", "replace")))

    for path, destination, changes in edit_changes(tool_input):
        if guard_source(full_path(destination), checkout):
            continue
        existing = read_text(full_path(path))
        shell = bool(SHELL_FILE_RE.search(destination)
                     or os.path.basename(destination) in SHELL_STARTUP_FILES
                     or shebang(existing) or any(shebang(new) for _old, new in changes))
        if not shell and not SOURCE_FILE_RE.search(destination):
            continue
        for old, new in changes:
            if len(new) > EDIT_MAX_BYTES:
                return (f"Blocked: this edit writes more than {EDIT_MAX_BYTES >> 20} MB into "
                        f"{os.path.basename(destination)}, too much for the signalling check to "
                        "read. Make the change in smaller parts.")
            counts = collections.Counter(signalling_text(new, shell, destination))
            counts.subtract(collections.Counter(
                signalling_text(existing if old is None else old, shell, destination)))
            introduced = sorted(shown for shown, count in counts.items() if count > 0)
            if introduced:
                # The file's name, not its path: a long path would push the
                # reason out of the one pipe write a denial has (see denial()).
                return (f"Blocked: this edit to {os.path.basename(destination)} introduces "
                        f"`{introduced[0]}`.\n\nIt signals a "
                        f"process group or chooses its targets by name or pattern.{SIGNAL_RULE}")
    return None


def check_command(command, typed=True, prompts=True):
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
    if typed and prompts and runs_script_string(command):
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


# Heavy work goes through the memory queue. On 2026-11-05 about ten agent
# sessions and the CI runners ran 31 tsc, 8 tsgolint and 92 node processes at
# once and the Mac swapped itself into a kernel kill of system daemons
# (modules/darwin/membrake.nix has the evidence). `membrake exec` waits for a
# turn when memory is short and otherwise runs the command at once, so the
# global instructions require it for heavy work; this rule makes the
# requirement hold for an agent that skipped the prose.
#
# Judged on the segment's program after runners are peeled (check() records
# whether a queue runner was among them), so `membrake exec -- vitest` and
# `timeout 60 cpu-lock run -- vitest` pass while `timeout 60 vitest` does not.
# Inspection (--version, --help, tsc --showConfig, cargo metadata) passes, but
# only where it asks the program being judged: among that program's own options
# (before any `--`), from a launcher about itself (`npx --version vitest` prints
# npx's version), or to the program a launcher runs (`npx vitest --version`).
# Past a `--`, in a just recipe's arguments, or after a bun, pnpm or yarn
# script's name (npm reads its own flags there), a flag is handed to something
# that compiles or runs first (see walk()).
# Scripts a command runs are not judged: a script already run under the queue
# is queued as a whole, and judging its lines would deny the wrapped form.
HEAVY_DENIAL = ('heavy command outside the memory queue: run it as membrake exec '
                '--label "<repo>: <what>" -- <command> (it waits for memory when the Mac '
                'is full; run long ones in the background)')
HEAVY_PROGRAMS = {"tsc", "tsgo", "tsgolint", "vitest", "jest", "playwright", "xcodebuild"}
HEAVY_CARGO = {"build", "test", "clippy", "bench", "nextest", "check"}
HEAVY_SWIFT = {"build", "test"}
PACKAGE_MANAGERS = {"bun", "pnpm", "npm", "yarn"}
# A just recipe or package script is heavy when its name says it runs tests,
# checks or builds: a heavy word that is a whole piece of the name (`unit-test`,
# `ci:build`, `scripts/verify.sh`) or that starts it (`tests`, `typecheck-all`).
# A word inside another (`latest`, `contest`, `rebuild`) is not one.
HEAVY_WORDS = ("test", "check", "typecheck", "verify", "build", "gate", "lint")
NAME_PIECES_RE = re.compile(r"[:\-_/.]")
INSPECTION_FLAGS = {"--version", "-V", "--help", "-h", "-help", "-version", "--showConfig",
                    "--init", "-list", "-showsdks", "-showBuildSettings", "-usage"}
# Playwright subcommands that download or open files rather than run tests.
PLAYWRIGHT_LIGHT = {"install", "install-deps", "show-report", "show-trace"}
# Flags whose value is a separate word, so it is not mistaken for a command.
PACKAGE_VALUE_FLAGS = {"--filter", "-F", "-C", "--dir", "--prefix", "--cwd", "--workspace"}
# `just --help`; --set takes two words, of which only the first is skipped.
JUST_VALUE_FLAGS = {"-f", "--justfile", "-d", "--working-directory", "-E", "--dotenv-path",
                    "--chooser", "--shell", "--color", "--unstable-format", "--alias-style",
                    "--ceiling", "--command-color", "--cygpath", "--dotenv-filename",
                    "--dump-format", "--evaluate-format", "--group", "--indentation",
                    "--justfile-name", "--list-heading", "--list-prefix", "--set",
                    "--shell-arg", "--tempdir", "--timestamp-format"}
JUST_OVERRIDE_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*=")
JUST_INSPECTION = {"--list", "-l", "--summary", "--show", "-s", "--dry-run", "-n",
                   "--evaluate", "--dump", "--fmt", "--choose", "--version", "--help", "-h"}
# `cargo --help` and `cargo test --help`: options that take a separate word, which
# stands between `cargo` and its subcommand (`cargo --config net.offline=true
# test`). The same for `swift build --help`, SwiftPM's options.
CARGO_VALUE_FLAGS = {"--config", "-Z", "--color", "-C", "--manifest-path", "-m", "--target-dir",
                     "--lockfile-path", "--explain"}
SWIFT_VALUE_FLAGS = {"--package-path", "--scratch-path", "--cache-path", "--config-path",
                     "--security-path", "-c", "--configuration", "--triple", "--sdk",
                     "--toolchain", "--swift-sdk", "--sanitize", "-Xcc", "-Xswiftc", "-Xlinker",
                     "-Xcxx", "-j", "--jobs", "--build-system"}


def heavy_name(name):
    """True for a just recipe or package script named for tests, checks or builds."""
    name = name.lower()
    return name.startswith(HEAVY_WORDS) or any(p in HEAVY_WORDS for p in NAME_PIECES_RE.split(name))


def walk(args, value_flags=()):
    """Classify the words of `args` as a program's option parser would.

    Pairs of (kind, index into args): "flag" (starts with `-`), "value" (the word
    after a flag in `value_flags`), "word", "dash" (the `--`), and "rest" for each
    word after it. Only what comes before `--` can be an option of this program;
    what follows belongs to whatever it runs (`cargo test -- --help` compiles, then
    hands --help to the test binary). A "rest" word is still a word of the
    program's own command line: `npm run -- test` runs the script `test`, so
    callers that look for the command or script name take "word" and "rest"
    alike and only the flags are confined to what comes before `--`."""
    out, i = [], 0
    while i < len(args):
        if args[i] == "--":
            out.append(("dash", i))
            out.extend(("rest", j) for j in range(i + 1, len(args)))
            break
        if args[i] in value_flags:
            out.append(("flag", i))
            if i + 1 < len(args):
                out.append(("value", i + 1))
            i += 2
        else:
            out.append(("flag" if args[i].startswith("-") else "word", i))
            i += 1
    return out


def positionals(args, value_flags=()):
    """The words of `args` that are neither options nor the value of an option."""
    return [args[i] for kind, i in walk(args, value_flags) if kind in ("word", "rest")]


def inspecting(args, value_flags=()):
    """True when `args` ask the program itself for help, a version or its
    configuration: an inspection flag among its own options (see walk())."""
    return any(kind == "flag" and args[i] in INSPECTION_FLAGS for kind, i in walk(args, value_flags))


# What `--version` and `--help` mean to the package managers and launchers
# themselves, observed with npm 11.19.0 and bun 1.4.3 (`npm -v`, `npm -h`,
# `bunx -v`, `bunx -h`; `-V` and `--showConfig` are not inspection there, they
# are unknown options, and `npm exec --showConfig -- vitest run` runs vitest).
# pnpm and yarn are not installed here: they accept the same four.
LAUNCHER_INSPECTION = {"--version": "version", "-v": "version", "--help": "help", "-h": "help"}


def asks_inspection(flags):
    """True when these flags, in order, leave a launcher or package manager asked
    for its own version or help. The last occurrence of each decides, as npm's
    parser does (`npm --version --version=false exec -- vitest` runs vitest).
    Only a bare flag or `=true` asks; any other value is a cancellation or
    something not known to ask, and a command is then judged as the work it runs."""
    asked = {}
    for flag in flags:
        name, attached, value = flag.partition("=")
        topic = LAUNCHER_INSPECTION.get(name)
        if topic:
            asked[topic] = not attached or value == "true"
    return any(asked.values())


# Programs that launch another program named by their first positional word:
# `npx vitest`, `bunx tsc`. Package managers do the same through a subcommand
# (`pnpm exec vitest`, `yarn dlx tsc`), and `nix develop|shell` through `-c`.
PACKAGE_LAUNCHERS = {"npx", "bunx", "pnpx"}
PACKAGE_LAUNCH_SUBCOMMANDS = {"exec", "dlx", "x"}
# Each launcher's own options: those that take a separate word (so the word after
# `--package typescript` is the program, not the package) and those whose word is
# a shell command line (`npx -c 'tsc --noEmit'`, `pnpm dlx -c '…'`). npm's and
# bun's are from `npm exec --help` and `bunx --help`; pnpm and yarn are not
# installed here, so theirs are not checked against a binary.
NPM_EXEC = ({"--package", "-p", "--workspace", "-w", "--allow-scripts", "--prefix", "--cache",
             "--registry", "--userconfig", "--globalconfig", "--loglevel"}, {"--call", "-c"})
BUN_X = ({"--package", "-p"}, set())
PNPM_DLX = ({"--package", "-p", "--filter", "-F", "--dir", "-C", "--reporter", "--loglevel",
             "--allow-build", "--workspace-concurrency"}, {"--shell-mode", "-c"})
YARN_DLX = ({"--package", "-p"}, set())
LAUNCHER_OPTIONS = {"npx": NPM_EXEC, "npm": NPM_EXEC, "bunx": BUN_X, "bun": BUN_X,
                    "pnpx": PNPM_DLX, "pnpm": PNPM_DLX, "yarn": YARN_DLX}


def package_command(word):
    """The program a launcher word names: `vitest@latest` and `@scope/tool@1.2`
    run `vitest` and `tool`."""
    name = os.path.basename(word)
    return name.split("@", 1)[0] or name


# Message arguments that are only ever text: `git commit -m`, `git tag -m`,
# `gh pr create --body`. split_segments() has no quote context, so a quoted
# message whose body reports `bun run lint exit 0` on its own line, or says
# `lint; vitest passed`, was judged as a command (nix-config#264).
# Only built-in subcommands, named directly after the program: Git and gh
# both refuse an alias that shadows a built-in, while an arbitrary Git alias
# (`git -c alias.x='!…' x -m '…'`) can run its "message".
MESSAGE_FLAGS = {
    ("git", "commit"): {"-m", "--message"},
    ("git", "tag"): {"-m", "--message"},
    ("git", "merge"): {"-m"},
    ("git", "stash"): {"-m", "--message"},
    ("gh", "pr"): {"-b", "--body", "-t", "--title"},
    ("gh", "issue"): {"-b", "--body", "-t", "--title"},
    ("gh", "release"): {"-n", "--notes", "-t", "--title"},
}


# Built-in subcommands a command line may consist of for its messages to be
# blanked. Every command in the line must be one of these, named directly
# after the program: then nothing else in the line can define, alias, trap,
# source or evaluate anything that would make `git` or `gh` run its message.
# Git and gh both refuse aliases that shadow built-ins.
PLAIN_SUBCOMMANDS = {
    "git": {"add", "commit", "tag", "merge", "stash", "status", "log", "diff", "show",
            "fetch", "pull", "push", "switch", "checkout", "branch", "restore", "rm", "mv"},
    "gh": {"pr", "issue", "release"},
}
# The only characters the scan accepts outside quotes. Anything else —
# expansions, globs, braces, redirections, subshells, history — means the
# shell may do something this scan does not model, so the command is left
# for the guard's ordinary rules, exactly as before.
PLAIN_UNQUOTED = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./=:@%+,-")


def blank_literal_messages(command):
    """`command` with the text of literal quoted message arguments removed.

    Only a message that cannot run anything is blanked: a single-quoted word,
    or a double-quoted one with no `$`, backtick or backslash in it, given
    whole as the value of a flag in MESSAGE_FLAGS, right after a built-in
    data subcommand (`git commit -m '…'`, `--message="…"`). Removing such text
    changes nothing the shell executes.

    The scan is an allow-list. Every command in the line must be `git` or
    `gh` with a PLAIN_SUBCOMMANDS subcommand; outside quotes only
    PLAIN_UNQUOTED characters, blanks, `;`, `&`, `|`, newlines, `#` comments
    and backslash escapes; a double-quoted word must hold no `$`, backtick or
    backslash; quotes must balance; no `<<` anywhere (the guard's heredoc
    stripping does not read quotes). Any other command is returned unchanged,
    so the guard judges it exactly as before."""
    if "<<" in command:
        return command
    # `started` is whether a word has begun, even as an empty quoted word
    # (`''`): the shell treats `''#` as an argument, not a comment.
    out, words, word, started = [], [], "", False
    i, n = 0, len(command)

    def invocation():
        # The command's words with git's leading `-C <dir>` pairs removed:
        # `-C` only changes git's working directory (unlike `-c`, which sets
        # configuration and is not skipped).
        rest = words[1:]
        if words[:1] == ["git"]:
            while rest[:1] == ["-C"] and len(rest) >= 2:
                rest = rest[2:]
        return words[:1] + rest

    def flag_before():
        call = invocation()
        flags = MESSAGE_FLAGS.get(tuple(call[:2])) if len(call) >= 2 else None
        if not flags:
            return False
        if started:  # only `--message="…"` may precede the quote in its word
            name, eq, rest = word.partition("=")
            return eq == "=" and not rest and name in flags
        return call[-1] in flags

    def end_word():
        nonlocal word, started
        if started:
            words.append(word)
        word, started = "", False

    def plain_command():
        # True when the command just ended is empty or a plain git/gh call.
        end_word()
        call = invocation()
        return not words or (
            len(call) >= 2 and call[1] in PLAIN_SUBCOMMANDS.get(call[0], ()))

    while i < n:
        c = command[i]
        if c == "\\":
            escaped = command[i + 1:i + 2]
            if escaped in ("", "\n"):
                return command  # line continuation: joined before comments are read
            out.append(command[i:i + 2])
            word += escaped
            started = True
            i += 2
        elif c in "'\"":
            close = command.find(c, i + 1)
            if close == -1:
                return command  # unbalanced: not this scan's to judge
            body = command[i + 1:close]
            if c == '"' and re.search(r"[$`\\]", body):
                return command  # an expansion inside double quotes
            if flag_before() and (close + 1 == n or command[close + 1] in " \t\n;&|"):
                out.append(c + c)
            else:
                out.append(command[i:close + 1])
            word += body
            started = True
            i = close + 1
        elif c in " \t":
            end_word()
            out.append(c)
            i += 1
        elif c in ";&|\n":
            if not plain_command():
                return command
            words = []
            out.append(c)
            i += 1
        elif c == "#" and not started:
            close = command.find("\n", i)
            close = n if close == -1 else close
            out.append(command[i:close])
            i = close
        elif c in PLAIN_UNQUOTED or c == "#":
            out.append(c)
            word += c
            started = True
            i += 1
        else:
            return command  # an unquoted character this scan does not model
    if not plain_command():
        return command
    return "".join(out)


def heavy_line(text):
    """True when a shell command line, such as an `npx --call` string, runs a
    heavy command outside the queue."""
    for segment in split_segments(text):
        try:
            tokens = shlex.split(segment)
        except ValueError:
            tokens = [t.strip("'\"") for t in segment.split()]
        queued = False
        while tokens:
            layer = peel(tokens)
            if layer is None:
                break
            tokens, via_queue = layer
            queued = queued or via_queue
        if tokens and not queued and is_heavy(os.path.basename(tokens[0]), tokens[1:]):
            return True
    return False


def launcher_heavy(launcher, args):
    """True when `launcher` (`npx`, or `exec`/`dlx` of a package manager) with
    these arguments runs a heavy command. Its own options come first; the first
    word after them (also past a `--`) is the program, and everything after that
    is the program's. An inspection flag among the launcher's options asks the
    launcher itself, which runs nothing (`npx --version vitest` prints npx's
    version); only the launcher's real ones count, and a later `=false` cancels."""
    value_flags, call_flags = LAUNCHER_OPTIONS[launcher]
    parts = walk(args, value_flags | call_flags)
    program = next((n for n, (kind, _) in enumerate(parts) if kind in ("word", "rest")), len(parts))
    options = parts[:program]
    if asks_inspection(args[i] for kind, i in options if kind == "flag"):
        return False
    for n, (kind, i) in enumerate(options):
        word = args[i]
        if kind != "flag":
            continue
        if word in call_flags and n + 1 < len(options):
            return heavy_line(args[options[n + 1][1]])
        for flag in call_flags:
            if word.startswith(flag + "="):
                return heavy_line(word[len(flag) + 1:])
    if program == len(parts):
        return False
    at = parts[program][1]
    return is_heavy(package_command(args[at]), args[at + 1:])


def manager_flags(prog):
    return PACKAGE_VALUE_FLAGS | ({"-w"} if prog == "npm" else set())


def is_heavy(prog, args):
    """True when this program, run bare, is one of the known heavy commands."""
    if prog in PACKAGE_LAUNCHERS:
        return launcher_heavy(prog, args)
    if prog in PACKAGE_MANAGERS:
        parts = walk(args, manager_flags(prog))
        words = [i for kind, i in parts if kind in ("word", "rest")]
        if not words:
            return False
        # Flags before the subcommand are the manager's own: `npm --version
        # exec vitest` prints a version.
        if asks_inspection(args[i] for kind, i in parts if kind == "flag" and i < words[0]):
            return False
        if args[words[0]] in PACKAGE_LAUNCH_SUBCOMMANDS:
            return launcher_heavy(prog, args[words[0] + 1:])
        # A script: `test`, or `run NAME` for a heavy name. Flags after the script
        # are its own arguments, except where the manager reads them first: npm
        # until `--`, and bun's built-in `bun test`.
        if args[words[0]] == "test":
            script_at = words[0]
        elif args[words[0]] in ("run", "run-script") and len(words) > 1 \
                and heavy_name(args[words[1]]):
            script_at = words[1]
        else:
            return False
        reads_flags_after = prog == "npm" or (prog == "bun" and script_at == words[0])
        return not asks_inspection(args[i] for kind, i in parts
                                   if kind == "flag" and (i < script_at or reads_flags_after))
    if prog == "nix":
        for flag in ("-c", "--command"):
            if flag in args and args.index(flag) + 1 < len(args):
                i = args.index(flag)
                return is_heavy(os.path.basename(args[i + 1]), args[i + 2:])
        return False
    if prog in SHELL_INTERPRETERS:  # `bash scripts/run-gate.sh`
        words = positionals(args)
        return bool(words) and fnmatch.fnmatch(os.path.basename(words[0]), "run-gate*")
    if fnmatch.fnmatch(prog, "run-gate*"):
        return True
    if prog == "just":
        # just's options come before the first recipe; after it a flag is that
        # recipe's argument (`just test --dry-run` runs test).
        parts = walk(args, JUST_VALUE_FLAGS)
        # `--set NAME VALUE` takes two words; walk() keeps the first as its value.
        second = {i + 2 for kind, i in parts if kind == "flag" and args[i] == "--set"}
        parts = [(kind, i) for kind, i in parts if i not in second]
        for kind, i in parts:
            if kind in ("word", "dash", "rest"):
                break
            if kind == "flag" and args[i] in JUST_INSPECTION:
                return False
        # Only the recipe name is judged. Its arguments are free text (`just wt
        # fix/test-flakes` names a branch), and just cannot be told apart from
        # a second recipe without reading the justfile; `just build test` is
        # caught by its first recipe.
        # Overrides (`just mode=release test`) come before it and are not it.
        recipe = next((args[i] for kind, i in parts if kind in ("word", "rest")
                       and not JUST_OVERRIDE_RE.match(args[i])), None)
        return recipe is not None and heavy_name(recipe)
    value_flags = CARGO_VALUE_FLAGS if prog == "cargo" else SWIFT_VALUE_FLAGS if prog == "swift" else ()
    if inspecting(args, value_flags):
        return False
    if prog == "playwright":
        words = positionals(args)
        return bool(words) and words[0] not in PLAYWRIGHT_LIGHT
    if prog in HEAVY_PROGRAMS:
        return True
    if prog in ("cargo", "swift"):
        # `cargo +nightly test`: a toolchain selector is not the subcommand.
        words = [args[i] for kind, i in walk(args, value_flags)
                 if kind == "word" and not args[i].startswith("+")]
        return bool(words) and words[0] in (HEAVY_CARGO if prog == "cargo" else HEAVY_SWIFT)
    return False


def check(segment, typed=True, heavy=True, others=True):
    """The denial reason for one segment. `heavy` and `others` select the
    heavy-command rule and every other rule; command_verdict() judges the
    heavy rule on literal-message-blanked segments and the rest on the
    command as typed, with the same tokenising and peeling for both."""
    raw = segment.strip()
    try:
        tokens = shlex.split(raw)
    except ValueError:
        tokens = raw.split()
    if not tokens:
        return None

    # Peel wrappers, runners and leading VAR=value assignments. The biometric
    # rule is judged at every layer, so a runner cannot hide an `env -i`.
    queued = False
    while tokens:
        if others and reenables_app_integration(tokens):
            return ("Blocked: setting, unsetting or dropping OP_BIOMETRIC_UNLOCK_ENABLED (including "
                    "`env -i`). Agent commands run with it false so nothing they run can reach the "
                    "1Password desktop app or raise a Touch ID prompt. The steps that need the owner "
                    "have declared commands that ask deliberately; see the credentials rules.")
        layer = peel(tokens)
        if layer is None:
            break
        tokens, via_queue = layer
        queued = queued or via_queue
    if not tokens:
        return None

    prog = os.path.basename(tokens[0])
    args = tokens[1:]
    flagless = [a for a in args if not a.startswith("-")]
    sub = flagless[0] if flagless else ""

    if heavy and typed and not queued and is_heavy(prog, args):
        return HEAVY_DENIAL
    if not others:
        return None

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
    if len(data) > SCRIPT_MAX_BYTES:
        return None
    text = expand_assignments(data.decode("utf-8", "replace"))
    if repository_script(full):
        # Its own lines pass, but not the files it runs: on 2026-11-11 the
        # typed script and the one below it were unchanged, and the edited
        # file was the one they sourced.
        inner, reason = [], None
        walk_script(text, inner, None)
        for inner_path, inner_kind in inner:
            reason = script_verdict(inner_path, inner_kind, cwd, depth + 1, seen)
            if reason:
                break
    else:
        reason = command_verdict(text, cwd, depth + 1, seen, typed=False)
    # The file's name, not its path, for the same reason as in edit_verdict().
    return reason and f"Blocked: the script {os.path.basename(path)} would run this.\n\n{reason}"


def command_verdict(command, cwd=None, depth=0, seen=None, typed=True, prompts=True):
    """The denial reason for a typed command or a script's text, or None.
    Text nested too deeply to read is refused, not passed."""
    try:
        return read_command(command, cwd, depth, seen, typed, prompts)
    except (TooDeep, RecursionError):
        return TOO_DEEP


def read_command(command, cwd, depth, seen, typed, prompts):
    """command_verdict()'s work.

    `prompts` selects the rule that exists only because Claude Code stops to
    ask the owner about a script string; Codex asks nothing, so its hook
    passes False. The unquoted-heredoc rule stays for both: it is what keeps
    a command inside a heredoc's substitution from running unread."""
    seen = set() if seen is None else seen
    reason = check_command(command, typed, prompts)
    if reason:
        return reason
    for segment in split_segments(command):
        reason = check(segment, typed, heavy=False)
        if reason:
            return reason
    # The heavy rule, with literal message text blanked first
    # (see blank_literal_messages); everything else as typed.
    for segment in split_segments(blank_literal_messages(command)):
        reason = check(segment, typed, others=False)
        if reason:
            return reason
    scripts, commands = [], []
    if typed:
        runs_script_string(command, scripts, commands)
    else:
        walk_script(command, scripts, commands)
    reason = signal_verdict(commands)
    if reason:
        return reason
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

    if not isinstance(payload, dict):
        sys.exit(0)
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        sys.exit(0)
    # `--client codex` and `--nix-config CHECKOUT`, each optional, as
    # ai/hooks/default.nix declares them. Anything else keeps the defaults,
    # which are the stricter ones.
    options = dict(zip(sys.argv[1::2], sys.argv[2::2]))
    cwd = payload.get("cwd")
    cwd = cwd if isinstance(cwd, str) else None
    tool_name = payload.get("tool_name")
    try:
        if isinstance(tool_name, str) and tool_name in EDIT_TOOLS:
            reason = edit_verdict(tool_input, cwd, options.get("--nix-config"))
        else:
            command = tool_input.get("command")
            if not isinstance(command, str) or not command:
                sys.exit(0)
            reason = command_verdict(command, cwd, prompts=options.get("--client") != "codex")
    except Exception as error:
        # A hook that raises lets the tool call run, so a defect here would
        # be a hole. It is a refusal instead, naming the defect.
        reason = (f"Blocked: the command guard failed while reading this ({type(error).__name__}), "
                  "so it cannot be judged. Write it more plainly, and report the failure.")
    if reason:
        deny(reason)

    sys.exit(0)


if __name__ == "__main__":
    main()
