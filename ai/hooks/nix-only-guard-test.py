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
import sys

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


def verdict(command):
    """The guard's decision for a command, without running anything."""
    if guard.check_command(command):
        return "DENY"
    for segment in guard.split_segments(command):
        if guard.check(segment):
            return "DENY"
    return "ALLOW"


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
    # ---- Connect administration the owner allowed (2026-10-07). ----
    ("list Connect servers", "op connect server list", "ALLOW"),
    ("grant a Connect server a vault", "op connect vault grant --server SomeServer --vault SomeVault", "ALLOW"),
    ("issue a Connect token", "op connect token create name --server SomeServer --vault SomeVault > /tmp/t", "ALLOW"),
    # ---- ...and nothing else under op. ----
    ("listing Connect tokens", "op connect token list --server SomeServer", "ALLOW"),
    ("deleting a replaced Connect token", "op connect token delete name --server SomeServer", "ALLOW"),
    ("deleting a Connect server", "op connect server delete SomeServer", "DENY"),
    ("revoking a vault grant", "op connect vault revoke --server SomeServer --vault SomeVault", "DENY"),
    # ---- Creating a vault (owner request 2026-10-07); nothing else on vaults. ----
    ("create a vault", "op vault create SomeVault", "ALLOW"),
    ("create a vault with a description", "op vault create 'Some Vault' --description x", "ALLOW"),
    ("delete a vault", "op vault delete SomeVault", "DENY"),
    ("edit a vault", "op vault edit SomeVault --name Other", "DENY"),
    # Granting a person a vault (owner request 2026-10-08); revoking stays blocked.
    ("grant a person a vault", "op vault user grant --vault SomeVault --user someone", "ALLOW"),
    ("revoke a person's vault access", "op vault user revoke --vault SomeVault --user someone", "DENY"),
    ("create an item", "op item create --vault SomeVault --category login", "DENY"),
    # ---- Moving an item between vaults (owner request 2026-10-07). ----
    ("move an item to another vault", "op item move SomeItem --current-vault A --destination-vault B > /dev/null", "ALLOW"),
    ("reading the moved item stays blocked", "op item get SomeItem --vault B", "DENY"),
    ("the mv alias, output discarded", "op item mv SomeItem --current-vault A --destination-vault B >/dev/null", "ALLOW"),
    ("a move that prints the item", "op item move SomeItem --current-vault A --destination-vault B", "DENY"),
    ("a move that reveals concealed fields", "op item move SomeItem --current-vault A --destination-vault B --reveal > /dev/null", "DENY"),
    ("a move whose output goes to a file", "op item move SomeItem --current-vault A --destination-vault B > /tmp/item", "DENY"),
    ("reading an item through the CLI", "op item get SomeItem", "DENY"),
    ("editing an item through the CLI, output shown", "op item edit SomeItem --vault SomeVault field=value", "DENY"),
    # Editing an item (owner request 2026-10-08), under the move rule.
    ("editing an item, output discarded", "op item edit SomeItem --vault SomeVault field=value > /dev/null", "ALLOW"),
    ("editing an item with --reveal", "op item edit SomeItem --vault SomeVault field=value --reveal > /dev/null", "DENY"),
    ("deleting an item", "op item delete SomeItem", "DENY"),
    ("connect as a flag value is not the subcommand", "op read --account connect op://SomeVault/SomeItem/field", "DENY"),
    ("stripping the service-account token", "env -u OP_SERVICE_ACCOUNT_TOKEN bun scripts/with-onepassword.mjs --check", "DENY"),
    ("unsetting the token", "unset OP_SERVICE_ACCOUNT_TOKEN; bun run deploy", "DENY"),
    ("overriding Connect", "OP_CONNECT_HOST=http://evil bun run deploy", "DENY"),
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
]


def main():
    failures = 0
    for name, command, expected in CASES:
        got = verdict(command)
        if got != expected:
            failures += 1
            print(f"FAIL  expected {expected:<5} got {got:<5}  {name}", file=sys.stderr)

    if failures:
        print(
            f"\n{failures} of {len(CASES)} nix-only-guard tests failed.\n"
            "A newly ALLOWED case means the guard was loosened; a newly DENIED "
            "case means a false positive was reintroduced.",
            file=sys.stderr,
        )
        return 1

    print(f"nix-only-guard: {len(CASES)}/{len(CASES)} tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
