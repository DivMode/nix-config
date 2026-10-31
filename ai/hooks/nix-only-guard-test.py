#!/usr/bin/env python3
"""Regression tests for ai/hooks/nix-only-guard.py.

The guard denies Bash commands, so a false positive is not a nuisance — it
stops work and, worse, it teaches whoever hit it to reach for a way around the
guard. Measured across this machine's session history, most denials changed
nothing: they fired on text that merely NAMED a blocked mechanism.

The tests below therefore assert BOTH directions. Anything that only names a
blocked command must be allowed; anything that would actually run one must
still be denied. Loosening the guard without noticing is the failure this file
exists to catch, so the DENY cases matter more than the ALLOW ones.

Run directly, or via scripts/hooks/pre-commit.
"""

import importlib.util
import os
import subprocess
import sys
import tempfile

GUARD = os.path.join(os.path.dirname(os.path.abspath(__file__)), "nix-only-guard.py")

spec = importlib.util.spec_from_file_location("nix_only_guard", GUARD)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

# Assembled rather than written literally, so this test file is not itself a
# tripwire for the guard it tests — the same trap it is checking for.
KILL = "kill" + "all"
DEFAULTS_WRITE = "defaults " + "write"
GENERIC_USER = "someuser"
PIP = "pi" + "p"
BREAK = "--break-" + "system-packages"
GH_API = "https://api." + "github.com"
GH_UPLOADS = "https://uploads." + "github.com"


def verdict(command, cwd=None):
    """The guard's decision for a command, without running anything."""
    return "DENY" if guard.command_verdict(command, cwd) else "ALLOW"


CASES = [
    # ---- Text that only NAMES a blocked mechanism. Must be allowed. ----
    (
        "heredoc writing a Nix module that declares the blocked command",
        "python3 - <<'PY'\n"
        "text = '''\n"
        f"  /usr/bin/{KILL} -qu \"$USER\" Dock || true\n"
        "'''\n"
        "open('modules/home/example.nix','w').write(text)\n"
        "PY",
        "ALLOW",
    ),
    (
        "commit message naming the blocked mechanism it is explaining",
        "git commit -F - <<'MSG'\n"
        f"dock: declare the {KILL} refresh so the tile re-resolves\n"
        f"\nNothing runs {DEFAULTS_WRITE} by hand; Nix owns it.\n"
        "MSG",
        "ALLOW",
    ),
    (
        "quoted heredoc feeding a file, blocked word deep inside",
        f"cat > notes.md <<'EOF'\nNever run {KILL} by hand.\nEOF",
        "ALLOW",
    ),
    ("read-only inspection", "grep -rn Dock modules/darwin/dock.nix", "ALLOW"),
    ("the sanctioned path", "darwin-rebuild switch --flake .#example-mac", "ALLOW"),
    # ---- Credential boundary (2026-09-14). Must stay denied. ----
    ("the 1Password CLI, bare", "op whoami", "DENY"),
    ("the 1Password CLI reading an item", "op item get SomeItem --vault SomeVault --format json", "DENY"),
    ("the 1Password CLI through a wrapper", "env -u FOO op read op://SomeVault/SomeItem/field", "DENY"),
    # ---- Typed administration (allowed 2026-10-07/08) can no longer reach the
    # desktop app from an agent shell (OP_BIOMETRIC_UNLOCK_ENABLED=false), so
    # it is denied with directions to the declared commands. ----
    ("list Connect servers", "op connect server list", "DENY"),
    ("grant a Connect server a vault", "op connect vault grant --server SomeServer --vault SomeVault", "DENY"),
    ("issue a Connect token", "op connect token create name --server SomeServer --vault SomeVault > /tmp/t", "DENY"),
    ("deleting a replaced Connect token", "op connect token delete name --server SomeServer", "DENY"),
    ("create a vault", "op vault create SomeVault", "DENY"),
    ("grant a person a vault", "op vault user grant --vault SomeVault --user someone", "DENY"),
    ("move an item, output discarded", "op item move SomeItem --current-vault A --destination-vault B > /dev/null", "DENY"),
    ("editing an item, output discarded", "op item edit SomeItem --vault SomeVault field=value > /dev/null", "DENY"),
    ("reading an item through the CLI", "op item get SomeItem", "DENY"),
    # ---- The declared commands that replace them. ----
    ("vault creation as the service account", "nix-config-op-admin vault create SomeVault", "ALLOW"),
    ("an owner-only step", "nix-config-op-owner vault user grant --vault SomeVault --user someone", "ALLOW"),
    ("Connect access for a new vault", "nix-config-connect-rotate --add-vault SomeVault", "ALLOW"),
    ("connect as a flag value is not the subcommand", "op read --account connect op://SomeVault/SomeItem/field", "DENY"),
    ("stripping the service-account token", "env -u OP_SERVICE_ACCOUNT_TOKEN bun scripts/with-onepassword.mjs --check", "DENY"),
    ("unsetting the token", "unset OP_SERVICE_ACCOUNT_TOKEN; bun run deploy", "DENY"),
    ("overriding Connect", "OP_CONNECT_HOST=http://evil bun run deploy", "DENY"),
    # Re-enabling the desktop app for a command that runs `op` somewhere inside:
    # every way the 2026-10-31 fix review found, quoted or not.
    ("re-enabling the app integration", "OP_BIOMETRIC_UNLOCK_ENABLED=true just wt x", "DENY"),
    ("exporting it re-enabled", "export OP_BIOMETRIC_UNLOCK_ENABLED=true; just wt x", "DENY"),
    ("exporting it quoted", 'export "OP_BIOMETRIC_UNLOCK_ENABLED=true"; just wt x', "DENY"),
    ("an assignment on its own", "OP_BIOMETRIC_UNLOCK_ENABLED=true; just wt x", "DENY"),
    ("through env", "env OP_BIOMETRIC_UNLOCK_ENABLED=true just wt x", "DENY"),
    ("through env, quoted", 'env "OP_BIOMETRIC_UNLOCK_ENABLED=true" just wt x', "DENY"),
    ("declare -x, quoted", 'declare -x "OP_BIOMETRIC_UNLOCK_ENABLED=1"; just wt x', "DENY"),
    ("unsetting it", 'unset "OP_BIOMETRIC_UNLOCK_ENABLED"; just wt x', "DENY"),
    ("env --unset", "env --unset=OP_BIOMETRIC_UNLOCK_ENABLED just wt x", "DENY"),
    ("env -u", "env -u OP_BIOMETRIC_UNLOCK_ENABLED just wt x", "DENY"),
    ("an empty environment drops it", 'env -i HOME="$HOME" PATH="$PATH" just wt x', "DENY"),
    ("reading the variable is fine", "printenv OP_BIOMETRIC_UNLOCK_ENABLED", "ALLOW"),
    ("echoing its text is fine", "echo OP_BIOMETRIC_UNLOCK_ENABLED=true", "ALLOW"),
    ("searching for its text is fine", "grep -n 'export OP_BIOMETRIC_UNLOCK_ENABLED=true' notes.txt", "ALLOW"),
    ("unsetting something else is fine", "unset FOO; just wt x", "ALLOW"),
    ("env with another variable is fine", "env FOO=1 just --list", "ALLOW"),
    ("reading the token file", "cat ~/.config/op/service-account-token", "DENY"),
    ("reading connect.env", "grep HOST $HOME/.config/op/connect.env", "DENY"),
    # ---- Credential boundary: text that only names it. Must be allowed. ----
    ("the repository's own loader", "bun scripts/with-onepassword.mjs exec bun run deploy", "ALLOW"),
    ("a doc mentioning the CLI inside a quoted heredoc", "cat > notes.md <<'EOF'\nNever run op by hand.\nEOF", "ALLOW"),
    ("grep for the variable name in source", "grep -rn OP_SERVICE_ACCOUNT_TOKEN scripts/", "ALLOW"),
    # ---- Actual machine mutation. Must stay denied. ----
    ("bare invocation", f"/usr/bin/{KILL} -u {GENERIC_USER} LinearMouse", "DENY"),
    (
        "invocation after a heredoc has ended",
        f"cat > x <<'EOF'\nharmless\nEOF\n{KILL} LinearMouse",
        "DENY",
    ),
    (
        "heredoc piped INTO a shell really does execute its body",
        f"bash <<'EOF'\n{KILL} LinearMouse\nEOF",
        "DENY",
    ),
    ("sudo-wrapped invocation", f"sudo {KILL} LinearMouse", "DENY"),
    # ---- The self-restarting UI agents the owner allowed (2026-10-06). ----
    ("restart the Dock", f"{KILL} Dock", "ALLOW"),
    ("restart Finder, quietly, as a named user", f"/usr/bin/{KILL} -qu {GENERIC_USER} Finder".replace("-qu", "-q -u"), "ALLOW"),
    ("restart two UI agents at once", f"{KILL} SystemUIServer ControlCenter", "ALLOW"),
    ("restart the keyboard menu item", f"{KILL} TextInputMenuAgent", "ALLOW"),
    # ---- ...and nothing beyond them. ----
    ("a UI agent next to an application", f"{KILL} Dock LinearMouse", "DENY"),
    ("a signal flag", f"{KILL} -9 Dock", "DENY"),
    ("pattern matching could hit anything", f"{KILL} -m Dock", "DENY"),
    ("no process named", f"{KILL} -q", "DENY"),
    ("pkill is never allowed", "p" + f"kill -x Dock", "DENY"),
    (
        "defaults write",
        f"{DEFAULTS_WRITE} com.apple.dock autohide -bool true",
        "DENY",
    ),
    ("brew install", "brew install some-cask", "DENY"),
    # ---- uv owns Python (2026-10-06): installs into an interpreter. ----
    ("pip install", PIP + " install requests", "DENY"),
    ("pip through the interpreter", "python3 -m " + PIP + " install requests", "DENY"),
    ("a versioned pip by absolute path", "/usr/bin/" + PIP + "3.9 install --user requests", "DENY"),
    ("defeating PEP 668", PIP + "3 install --quiet " + BREAK + " websocket-client", "DENY"),
    ("defeating PEP 668 through the environment", "PIP_BREAK_SYSTEM_PACKAGES=1 " + PIP + " install x", "DENY"),
    ("uv installing into the base interpreter", "uv " + PIP + " install --system requests", "DENY"),
    # ...while uv's own ways, and reading about pip, stay allowed.
    ("a project venv through uv", "uv " + PIP + " install -r requirements.txt", "ALLOW"),
    ("a one-off dependency through uv", "uv run --with websocket-client python script.py", "ALLOW"),
    ("pip's version", PIP + "3 --version", "ALLOW"),
    ("listing what is installed", "python3 -m " + PIP + " list", "ALLOW"),
    ("grep for the flag", "grep -rn -- " + BREAK + " justfile", "ALLOW"),
    ("launchctl bootstrap", "launchctl bootstrap gui/501 some.plist", "DENY"),
    # ---- GitHub writes go through the wrapped gh (2026-10-09). ----
    ("curl POST to the API", "curl -X POST -H 'Authorization: token x' " + GH_API + "/repos/o/r/issues -d '{}'", "DENY"),
    ("curl with an attached method", "curl -XPATCH " + GH_API + "/repos/o/r/issues/1", "DENY"),
    ("curl sending JSON, method implied", "curl --json '{\"body\":\"x\"}' " + GH_API + "/repos/o/r/issues/1/comments", "DENY"),
    ("curl with a token from gh", "curl -d @body.json -H \"Authorization: Bearer $(gh auth token)\" " + GH_API + "/graphql", "DENY"),
    ("wget posting", "wget --post-data='x=1' " + GH_API + "/repos/o/r/issues", "DENY"),
    ("httpie with a write method", "http POST " + GH_API + "/repos/o/r/issues title=x", "DENY"),
    ("httpie sending a field", "xh " + GH_API + "/repos/o/r/issues title=x", "DENY"),
    ("an uploads host write", "curl -T asset.tar " + GH_UPLOADS + "/repos/o/r/releases/1/assets", "DENY"),
    ("a python heredoc posting to the API",
     "python3 - <<'PY'\nimport requests\nrequests.post('" + GH_API + "/repos/o/r/issues', json={})\nPY",
     "DENY"),
    ("a node one-liner patching the API",
     "node -e \"fetch('" + GH_API + "/repos/o/r/issues/1', {method: 'PATCH'})\"", "DENY"),
    # ...while reads, other hosts, gh itself, and prose stay allowed.
    ("curl GET from the API", "curl -s " + GH_API + "/repos/o/r/releases/latest", "ALLOW"),
    ("curl with an explicit GET", "curl -X GET " + GH_API + "/rate_limit", "ALLOW"),
    ("httpie reading with a query", "http " + GH_API + "/search/issues q==label:bug", "ALLOW"),
    ("curl POST to another host", "curl -X POST https://example.com/hook -d x", "ALLOW"),
    ("gh api write, which the wrapper checks", "gh api -X POST repos/o/r/issues -f title=x", "ALLOW"),
    ("python reading the API", "python3 -c \"import requests; print(requests.get('" + GH_API + "/rate_limit').json())\"", "ALLOW"),
    ("a commit message describing the rule",
     "git commit -F - <<'MSG'\nguard: deny curl -X POST to " + GH_API + "\nMSG", "ALLOW"),
    ("grep for the host", "grep -rn " + GH_API + " scripts", "ALLOW"),
    # ---- Unquoted heredocs run the substitutions in their body (2026-10-09). ----
    ("the incident: Markdown code spans in an unquoted prompt heredoc",
     "cat > prompt.md <<EOF\n# Review\nRun `just test` in the checkout.\n"
     "Check that `items.map(x => x.id)` is unchanged.\nEOF", "DENY"),
    ("$( in an unquoted body", "cat > notes.md <<EOF\nBuilt on $(date)\nEOF", "DENY"),
    ("a space before the delimiter", "cat << EOF > notes.md\nRun `ls`\nEOF", "DENY"),
    ("<<- with a tab-indented terminator", "cat <<-EOF > notes.md\n\tRun `ls`\n\tEOF", "DENY"),
    ("an unquoted heredoc inside a commit-message substitution",
     "git commit -m \"$(cat <<EOF\nRun `just test`\nEOF\n)\"", "DENY"),
    ("the second of two heredocs is unquoted",
     "cat > a <<'A'; cat > b <<B\n`literal`\nA\n$(date)\nB", "DENY"),
    # ...while literal bodies, plain $VAR, and text naming the pattern stay allowed.
    ("single-quoted delimiter", "cat > prompt.md <<'EOF'\nRun `just test` and $(date)\nEOF", "ALLOW"),
    ("double-quoted delimiter", "cat > prompt.md <<\"EOF\"\nRun `just test`\nEOF", "ALLOW"),
    ("backslash-quoted delimiter", "cat > prompt.md <<\\EOF\nRun `just test`\nEOF", "ALLOW"),
    ("plain variable expansion", "cat > notes.md <<EOF\nHome is $HOME and ${USER}\nEOF", "ALLOW"),
    ("arithmetic expansion in an unquoted body", "cat > notes.md <<EOF\nTotal $((1 + 2))\nEOF", "ALLOW"),
    ("escaped substitutions are literal", "cat > notes.md <<EOF\nUse \\`ls\\` and \\$(pwd)\nEOF", "ALLOW"),
    ("only the quoted one of two heredocs has backticks",
     "cat > a <<A; cat > b <<'B'\nplain $HOME\nA\n`literal`\nB", "ALLOW"),
    ("a here-string", "tr a-z A-Z <<<hello\necho \"$(date)\"", "ALLOW"),
    ("the common quoted commit-message heredoc",
     "git commit -m \"$(cat <<'EOF'\nRun `just test` before $(merging)\nEOF\n)\"", "ALLOW"),
    ("a commit message naming the pattern",
     "git commit -F - <<'MSG'\nguard: refuse cat <<EOF bodies\n\nA body with `just test` ran it.\nMSG", "ALLOW"),
    ("a quoted --body naming the pattern",
     "gh issue comment 1 --body 'An agent wrote cat > p.md <<EOF and the\n`just test` span ran.'", "ALLOW"),
    ("a one-line message naming the pattern",
     "git commit -m \"guard: refuse <<EOF bodies\"\necho \"$(git log -1 --format=%h)\"", "ALLOW"),
    ("grep for the pattern", "grep -n '<<EOF' ai/hooks/nix-only-guard.py\ngrep -n '$(' README.md", "ALLOW"),
    ("an arithmetic shift", "echo $((1 << 4))\necho \"$(date)\"", "ALLOW"),
    ("a comment naming the pattern", "# write it with <<EOF\necho \"$(date)\"", "ALLOW"),
    # ---- Script strings Claude Code cannot check and prompts for (#187). ----
    ("bash -c", "bash -c 'echo hi'", "DENY"),
    ("the incident: a wait loop under gtimeout",
     "gtimeout 60 bash -c 'until [ ! -e /tmp/lock ]; do sleep 20; done'", "DENY"),
    ("eval after &&", "cd /tmp && eval \"$setup\"", "DENY"),
    ("an absolute shell path", "/bin/bash -c 'echo hi'", "DENY"),
    ("combined flags", "zsh -lc 'echo hi'", "DENY"),
    ("an option with an argument before -c", "bash -o pipefail -c 'a | b'", "DENY"),
    ("env and nice wrappers", "env FOO=1 nice -n 5 sh -c 'echo hi'", "DENY"),
    ("timeout flags before the duration", "timeout -k 5 60 sh -c 'echo hi'", "DENY"),
    ("after a pipe through xargs", "ls | xargs -I {} sh -c 'echo {}'", "DENY"),
    ("inside a substitution in double quotes", "echo \"result: $(bash -c 'echo hi')\"", "DENY"),
    ("inside backticks in a double-quoted message", "git commit -m \"run `eval x`\"", "DENY"),
    ("as an if condition", "if eval true; then echo y; fi", "DENY"),
    ("in a heredoc fed to a shell", "cat <<'EOF' | bash\nbash -c 'echo hi'\nEOF", "DENY"),
    ("on a later line after a comment", "echo a # note; it's fine\nbash -c 'echo hi'", "DENY"),
    # ...while text naming it, and running a script file, stay allowed.
    ("grep for the pattern", "grep -rn 'bash -c' ai/hooks", "ALLOW"),
    ("grep for eval, unquoted", "grep -n eval scripts/rebuild.sh", "ALLOW"),
    ("a commit message heredoc quoting the rule",
     "git commit -F - <<'MSG'\nguard: deny bash -c and eval\n\nRun `bash -c 'x'` never; eval neither.\nMSG", "ALLOW"),
    ("a one-line commit message with separators", "git commit -m \"guard: deny x; bash -c y | eval z\"", "ALLOW"),
    ("a quoted --body naming the rule",
     "gh issue comment 187 --body 'Denied: gtimeout 60 bash -c ...; x && eval ...'", "ALLOW"),
    ("a substitution-wrapped commit heredoc",
     "git commit -m \"$(cat <<'EOF'\nguard: deny bash -c\nEOF\n)\"", "ALLOW"),
    ("a script file", "bash /tmp/scratch/wait.sh", "ALLOW"),
    ("a syntax check of a script file", "bash -n script.sh", "ALLOW"),
    ("-c after the script file is its argument", "bash script.sh -c", "ALLOW"),
    ("a script file under gtimeout", "gtimeout 60 bash wait.sh", "ALLOW"),
    ("echo naming it", "echo eval bash -c", "ALLOW"),
    ("an escaped separator", "echo a \\; bash -c x", "ALLOW"),
    ("python -c is not a shell", "python3 -c 'print(1)'", "ALLOW"),

    # ---- A runner in front hid the program (2026-10-31). cpu-lock is the
    # wrapper the global policy requires for heavy work. ----
    ("a write into ~/Library under gtimeout", "gtimeout 60 rm -r ~/Library/Caches/x", "DENY"),
    ("a write into ~/Library under timeout -k", "timeout -k 5 60 mkdir -p ~/Library/Caches/x", "DENY"),
    ("a write into ~/Library under cpu-lock",
     "cpu-lock run --shared --wait 3600 --label 'repo: x' -- mkdir -p ~/Library/Caches/x", "DENY"),
    ("a script string under cpu-lock",
     "cpu-lock run --shared --wait 3600 --label x -- bash -c 'echo hi'", "DENY"),
    ("an empty environment under cpu-lock",
     "cpu-lock run --shared --label x -- env -i HOME=/h just wt x", "DENY"),
    ("a write into ~/Library under nice", "nice -n 5 cp a ~/Library/Caches/x", "DENY"),
    ("a test run under cpu-lock",
     "cpu-lock run --shared --wait 3600 --label 'repo: tests' -- just verify", "ALLOW"),
    ("cpu-lock status", "cpu-lock status", "ALLOW"),
    ("a read of ~/Library under gtimeout", "gtimeout 60 ls ~/Library/Caches", "ALLOW"),
]

# ---- Files a command runs as shell. The guard never opened them, so a script
# did unseen what the guard denies when typed (2026-10-30: an agent's probe
# script created and filled ~/Library/Caches/tcc-probe-1248). Each file is
# written to a temporary directory; {d} in a command is that directory. ----
SCRIPT_FILES = {
    "probe.sh": ("#!/bin/bash\nset -u\nSRC=/src\nDST=\"$HOME/Library/Caches/tcc-probe-1248\"\n"
                 "mkdir -p \"$DST\"\ncp -R \"$SRC/.\" \"$DST/\"\n"),
    "plain.sh": "mkdir -p ~/Library/Caches/x\n",
    "outer.sh": "#!/bin/bash\necho start\nbash inner.sh\n",
    "inner.sh": "rm -r ~/Library/Caches/x\n",
    "after-string.sh": "#!/bin/bash\nbash -c 'echo hi'\nsource ./plain.sh\n",
    "exec.sh": "#!/usr/bin/env bash\ntouch ~/.config/x\n",
    "exec.py": "#!/usr/bin/env python3\n# mkdir -p ~/Library/Caches/x\n",
    "benign.sh": ("#!/bin/bash\nOUT=/tmp/out\nls ~/Library/Caches\nmkdir -p \"$OUT\"\n"
                  "cat > notes.md <<'EOF'\nnever mkdir -p ~/Library/Caches/x\nEOF\n"
                  "node cli.js install chromium\nbash -c 'echo hi'\n"),
}
SCRIPT_CASES = [
    ("the incident: a probe script whose writes go through $DST", "bash {d}/probe.sh", "DENY"),
    ("a script under zsh -li", "zsh -li {d}/plain.sh", "DENY"),
    ("a sourced script", "source {d}/plain.sh", "DENY"),
    ("a dot-sourced script", ". {d}/plain.sh", "DENY"),
    ("a script under cpu-lock", "cpu-lock run --shared --wait 3600 --label x -- bash {d}/plain.sh", "DENY"),
    ("a script relative to the session directory", "bash plain.sh", "DENY"),
    ("a script another script runs", "bash {d}/outer.sh", "DENY"),
    ("a script sourced after a script string in a file", "bash {d}/after-string.sh", "DENY"),
    ("a shell-shebang script run by path", "{d}/exec.sh", "DENY"),
    ("a python script run by path is not shell", "{d}/exec.py", "ALLOW"),
    ("a script that reads, writes elsewhere, and names writes in data", "bash {d}/benign.sh", "ALLOW"),
    ("a script that does not exist", "bash {d}/missing.sh", "ALLOW"),
    ("a script path the guard cannot resolve", "bash \"$S/plain.sh\"", "ALLOW"),
    ("a script only shown, not run", "cat {d}/plain.sh", "ALLOW"),
]


def main():
    failures = 0
    for name, command, expected in CASES:
        got = verdict(command)
        if got != expected:
            failures += 1
            print(f"FAIL  expected {expected:<5} got {got:<5}  {name}", file=sys.stderr)

    with tempfile.TemporaryDirectory() as d:
        for file, text in SCRIPT_FILES.items():
            with open(os.path.join(d, file), "w") as handle:
                handle.write(text)
        for name, command, expected in SCRIPT_CASES:
            got = verdict(command.format(d=d), cwd=d)
            if got != expected:
                failures += 1
                print(f"FAIL  expected {expected:<5} got {got:<5}  {name}", file=sys.stderr)

    # A script git tracks unchanged is the repository's own mechanism (another
    # repository's Connect loader clears OP_* before loading its own); once
    # edited, or never added, it is read like any scratch file.
    repository_cases = 0
    # pre-commit runs this with GIT_INDEX_FILE / GIT_DIR set to this
    # repository's; without clearing them the scratch repository's `git add`
    # stages into this one (it did, 2026-10-31).
    git_env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    with tempfile.TemporaryDirectory() as d:
        subprocess.run(["git", "init", "-q", d], check=True, env=git_env)
        loader = os.path.join(d, "loader.sh")
        with open(loader, "w") as handle:
            handle.write("unset OP_CONNECT_TOKEN\nmkdir -p ~/Library/Caches/x\n")
        for name, expected, step in [
            ("an untracked script is read", "DENY", None),
            ("a script git tracks unchanged is the repository's own", "ALLOW", ["add", "loader.sh"]),
            ("a tracked script edited after it was added is read", "DENY", "edit"),
        ]:
            if step == "edit":
                with open(loader, "a") as handle:
                    handle.write("echo edited\n")
            elif step:
                subprocess.run(["git", "-C", d, *step], check=True, env=git_env)
            repository_cases += 1
            got = verdict("bash loader.sh", cwd=d)
            if got != expected:
                failures += 1
                print(f"FAIL  expected {expected:<5} got {got:<5}  {name}", file=sys.stderr)

    total = len(CASES) + len(SCRIPT_CASES) + repository_cases
    if failures:
        print(
            f"\n{failures} of {total} nix-only-guard tests failed.\n"
            "A newly ALLOWED case means the guard was loosened; a newly DENIED "
            "case means a false positive was reintroduced.",
            file=sys.stderr,
        )
        return 1

    print(f"nix-only-guard: {total}/{total} tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
