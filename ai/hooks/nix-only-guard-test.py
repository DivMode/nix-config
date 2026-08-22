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


def verdict(command):
    """The guard's decision for a command, without running anything."""
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
    # ---- Actual machine mutation. Must stay denied. ----
    ("bare invocation", f"/usr/bin/{KILL} -u {GENERIC_USER} Dock", "DENY"),
    (
        "invocation after a heredoc has ended",
        f"cat > x <<'EOF'\nharmless\nEOF\n{KILL} Dock",
        "DENY",
    ),
    (
        "heredoc piped INTO a shell really does execute its body",
        f"bash <<'EOF'\n{KILL} Dock\nEOF",
        "DENY",
    ),
    ("sudo-wrapped invocation", f"sudo {KILL} Dock", "DENY"),
    (
        "defaults write",
        f"{DEFAULTS_WRITE} com.apple.dock autohide -bool true",
        "DENY",
    ),
    ("brew install", "brew install some-cask", "DENY"),
    ("launchctl bootstrap", "launchctl bootstrap gui/501 some.plist", "DENY"),
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
