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
import json
import os
import subprocess
import sys
import tempfile
import time

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
    # membrake exec is the same runner (cpu-lock is an alias for it).
    ("a write into ~/Library under membrake exec",
     "membrake exec --label 'repo: x' -- mkdir -p ~/Library/Caches/x", "DENY"),
    ("a script string under membrake exec",
     "membrake exec --label x -- bash -c 'echo hi'", "DENY"),
    ("an empty environment under membrake exec",
     "membrake exec --label x -- env -i HOME=/h just wt x", "DENY"),
    ("a test run under membrake exec",
     "membrake exec --label 'repo: tests' -- just verify", "ALLOW"),
    ("membrake status", "membrake status", "ALLOW"),

    # ---- Heavy commands run through the memory queue. Each family is denied
    # bare and allowed under membrake exec or cpu-lock run. ----
    ("tsc bare", "tsc --noEmit -p .", "DENY"),
    ("tsc under membrake exec", "membrake exec --label 'r: tsc' -- tsc --noEmit -p .", "ALLOW"),
    ("tsc under cpu-lock run", "cpu-lock run --shared --label 'r: tsc' -- tsc --noEmit -p .", "ALLOW"),
    ("tsgo bare", "tsgo --noEmit", "DENY"),
    ("tsgolint bare", "tsgolint .", "DENY"),
    ("tsgolint under membrake exec", "membrake exec --label x -- tsgolint .", "ALLOW"),
    ("vitest by path", "./node_modules/.bin/vitest run", "DENY"),
    ("vitest after a cd", "cd app && vitest run", "DENY"),
    ("vitest behind an assignment and timeout", "CI=1 timeout 600 vitest run", "DENY"),
    ("vitest under membrake exec", "membrake exec --label x -- vitest run", "ALLOW"),
    ("vitest under timeout inside membrake exec", "membrake exec --label x -- timeout 600 vitest run", "ALLOW"),
    ("vitest under cpu-lock inside timeout", "timeout 600 cpu-lock run --label x -- vitest run", "ALLOW"),
    ("jest bare", "jest --ci", "DENY"),
    ("jest under cpu-lock run", "cpu-lock run --label x -- jest --ci", "ALLOW"),
    ("playwright test bare", "playwright test", "DENY"),
    ("playwright test under membrake exec", "membrake exec --label x -- playwright test", "ALLOW"),
    ("xcodebuild bare", "xcodebuild -scheme App build", "DENY"),
    ("xcodebuild under membrake exec", "membrake exec --label x -- xcodebuild -scheme App build", "ALLOW"),
    ("cargo build bare", "cargo build --release", "DENY"),
    ("cargo test with a toolchain selector", "cargo +nightly test", "DENY"),
    ("cargo clippy bare", "cargo clippy --all-targets", "DENY"),
    ("cargo bench bare", "cargo bench", "DENY"),
    ("cargo nextest bare", "cargo nextest run", "DENY"),
    ("cargo check bare", "cargo check", "DENY"),
    ("cargo test under membrake exec", "membrake exec --label x -- cargo test", "ALLOW"),
    ("cargo test under cpu-lock run", "cpu-lock run --label x -- cargo test", "ALLOW"),
    ("swift build bare", "swift build -c release", "DENY"),
    ("swift test bare", "swift test", "DENY"),
    ("swift test under membrake exec", "membrake exec --label x -- swift test", "ALLOW"),
    ("bun test bare", "bun test", "DENY"),
    ("pnpm test bare", "pnpm test", "DENY"),
    ("pnpm test in a filtered workspace", "pnpm --filter web test", "DENY"),
    ("npm test bare", "npm test", "DENY"),
    ("yarn test bare", "yarn test", "DENY"),
    ("pnpm run typecheck", "pnpm run typecheck", "DENY"),
    ("npm run a test script with a suffix", "npm run test:unit -- --watch=false", "DENY"),
    ("bun run build", "bun run build", "DENY"),
    ("yarn run lint", "yarn run lint", "DENY"),
    ("npm run gate", "npm run gate", "DENY"),
    ("pnpm run verify", "pnpm run verify", "DENY"),
    ("npm run check:types", "npm run check:types", "DENY"),
    ("pnpm test under membrake exec", "membrake exec --label x -- pnpm test", "ALLOW"),
    ("bun run build under cpu-lock run", "cpu-lock run --label x -- bun run build", "ALLOW"),
    ("just verify bare", "just verify", "DENY"),
    ("just test bare", "just test", "DENY"),
    ("just lint bare", "just lint", "DENY"),
    ("just with a justfile flag", "just --justfile ci/justfile build", "DENY"),
    ("just verify under membrake exec", "membrake exec --label x -- just verify", "ALLOW"),
    ("run-gate script bare", "./scripts/run-gate.sh --all", "DENY"),
    ("run-gate script under a shell", "bash scripts/run-gate.sh", "DENY"),
    ("run-gate script under membrake exec", "membrake exec --label x -- ./scripts/run-gate.sh", "ALLOW"),
    # Inspection and non-heavy subcommands stay allowed.
    ("tsc --version", "tsc --version", "ALLOW"),
    ("tsc --showConfig", "tsc --showConfig -p .", "ALLOW"),
    ("tsc --help", "tsc --help", "ALLOW"),
    ("vitest --help", "vitest --help", "ALLOW"),
    ("jest --version", "jest --version", "ALLOW"),
    ("playwright --version", "playwright --version", "ALLOW"),
    ("playwright install", "playwright install chromium", "ALLOW"),
    ("xcodebuild -version", "xcodebuild -version", "ALLOW"),
    ("xcodebuild -showsdks", "xcodebuild -showsdks", "ALLOW"),
    ("cargo --version", "cargo --version", "ALLOW"),
    ("cargo metadata", "cargo metadata --format-version 1", "ALLOW"),
    ("cargo build --help", "cargo build --help", "ALLOW"),
    ("swift --version", "swift --version", "ALLOW"),
    ("npm --version", "npm --version", "ALLOW"),
    ("pnpm install", "pnpm install", "ALLOW"),
    ("npm run dev", "npm run dev", "ALLOW"),
    ("npm run latest", "npm run latest", "ALLOW"),
    ("bun run a script file", "bun run scripts/seed.ts", "ALLOW"),
    ("a package named test is not the test command", "pnpm add test-utils", "ALLOW"),
    ("just --list", "just --list", "ALLOW"),
    ("just --dry-run verify", "just --dry-run verify", "ALLOW"),
    ("just with a non-heavy recipe", "just wt feature", "ALLOW"),
    # A recipe's arguments are free text: only the recipe name is judged.
    ("just wt with a branch naming test", "just wt fix/test-flakes", "ALLOW"),
    ("just wt with a branch naming gate", "just wt fix/gate-x", "ALLOW"),
    ("just with a heavy first recipe and more", "just build deploy", "DENY"),
    # Launchers run the heavy program they name; judged as that program.
    ("npx vitest bare", "npx vitest run", "DENY"),
    ("bunx tsc bare", "bunx tsc --noEmit", "DENY"),
    ("pnpm exec vitest bare", "pnpm exec vitest run", "DENY"),
    ("yarn dlx tsc bare", "yarn dlx tsc -p .", "DENY"),
    ("pnpm --filter web exec vitest bare", "pnpm --filter web exec vitest", "DENY"),
    ("nix develop -c cargo test bare", "nix develop -c cargo test", "DENY"),
    ("nix shell --command vitest bare", "nix shell nixpkgs#nodejs --command vitest", "DENY"),
    ("npx vitest queued", "membrake exec --label x -- npx vitest run", "ALLOW"),
    ("nix develop -c cargo test queued", "cpu-lock run --shared --label x -- nix develop -c cargo test", "ALLOW"),
    ("npx with a light program", "npx prettier --check .", "ALLOW"),
    ("pnpm exec a light program", "pnpm exec eslint --version", "ALLOW"),
    ("nix develop -c a light program", "nix develop -c cargo metadata", "ALLOW"),
    ("nix build is not a launch", "nix build .#default", "ALLOW"),
    ("grep for a heavy command", "grep -rn 'vitest run' package.json", "ALLOW"),
    ("echo naming a heavy command", "echo run pnpm test next", "ALLOW"),
    ("a commit message naming a heavy command", "git commit -m 'ci: run vitest and cargo test'", "ALLOW"),
    # nix-config#264: a quoted message is one argument, whatever lines or
    # separators it contains; what the shell really runs is still judged.
    ("a multi-line commit message reporting a heavy result",
     "git commit -q -m \"fix: x\n\nbun run lint exit 0\"", "ALLOW"),
    ("separators inside a quoted commit message",
     "git commit -m 'fix: lint; bun run lint passed && vitest run | tee'", "ALLOW"),
    ("a --message= value spanning lines", "git commit --message=\"x\nvitest run\"", "ALLOW"),
    ("a tag message spanning lines", "git tag -a v1 -m \"x\ncargo test\n\"", "ALLOW"),
    # An empty quoted word starts a word: `''#` is an argument, not a comment.
    ("an empty quoted word before a hash", "git ''# '\ngit commit -m '\nvitest run\n# '", "DENY"),
    ("a message glued after an empty quoted word", "git commit -m ''\"x\nvitest run\"", "DENY"),
    ("a line continuation before a comment", "git commit \\\n# -m '\nvitest run\n# '", "DENY"),
    ("an arbitrary Git alias given a message",
     "git -c 'alias.r=!f() { eval \"$2\"; }; f' r -m 'x\nvitest run\n'", "DENY"),
    ("an unknown Git subcommand given a message", "git reviewprobe -m 'x\nvitest run\n'", "DENY"),
    ("git redefined with spaced parentheses",
     "git ( ) { printf \"%s\\n\" \"$3\" | bash; }\ngit commit -m ':\nvitest run\n'", "DENY"),
    ("git aliased after a tab", "alias\tgit='sh -s'\ngit commit -m ':\nvitest run\n'", "DENY"),
    ("git aliased with an escaped keyword", "ali\\as git='sh -s'\ngit commit -m ':\nvitest run\n'", "DENY"),
    ("a function keyword after a tab", "function\tgit { sh -s; }\ngit commit -m ':\nvitest run\n'", "DENY"),
    ("a function defined after a keyword",
     "if true; then function git { sh -s; }; fi\ngit commit -m ':\nvitest run\n'", "DENY"),
    ("an alias defined inside braces", "{ alias git='sh -s'; }\ngit commit -m ':\nvitest run\n'", "DENY"),
    ("a function definition with a comment between its parentheses",
     "git ( #c\n) { sh -s; }\ngit commit -m ':\nvitest run\n'", "DENY"),
    # Outside the allow-list the scan steps aside and main's rules apply,
    # which deny these as before: the cost of not modelling the shell.
    ("a subshell around a multi-line commit falls back",
     "(git commit -m 'x\nbun run lint exit 0')", "DENY"),
    ("an alias hidden behind a redirection",
     "alias>/dev/null git='eval : '\ngit commit -m ':\nvitest run\n'", "DENY"),
    ("an alias spelled with locale quoting",
     "$\"alias\" git='eval : '\ngit commit -m ':\nvitest run\n'", "DENY"),
    ("a redirected multi-line commit message falls back",
     "git commit -m 'x\nbun run lint exit 0' 2>&1", "DENY"),
    ("an alias produced by a variable", "a=alias\n$a git='eval : '\ngit commit -m ':\nvitest run\n'", "DENY"),
    ("an alias produced by brace expansion",
     "a{lias,} git='eval : '\ngit commit -m ':\nvitest run\n'", "DENY"),
    ("a redirection operand that looks like git", "<git commit -m ':\nvitest run\n'", "DENY"),
    ("a quoted heredoc introducer before a blanked message",
     "echo '<<EOF'; git commit -m 'bash'\nvitest run\nEOF", "DENY"),
    ("a trap that defines an alias", "trap 'alias git=x' DEBUG\n:\ngit commit -m ':\nvitest run\n'", "DENY"),
    # A substitution in a message runs in the shell before git sees it; the
    # pre-pass must leave such a message alone (main's rules then apply).
    ("a command substitution inside a multi-line message", "git commit -m \"$(\nvitest run\n)\"", "DENY"),
    ("a backtick substitution inside a multi-line message", "git commit -m \"`\nvitest run\n`\"", "DENY"),
    # `git -C <dir>` only changes directory, so it may precede the subcommand;
    # `git -c` sets configuration and still leaves the command unchanged.
    ("a message after git -C dir", "git -C /work/repo commit -q -m 'x\nbun run lint exit 0'", "ALLOW"),
    ("a message after two git -C dirs", "git -C /work -C repo commit -m 'x\nvitest run\n'", "ALLOW"),
    ("a message after git -c config", "git -c core.x=y commit -m 'x\nvitest run\n'", "DENY"),
    ("a dangling git -C before a message", "git -C -m 'x\nvitest run\n'", "DENY"),
    ("an add and commit chain stays useful", "git add -A && git commit -m 'x\nbun run lint exit 0'", "ALLOW"),
    ("message words that name definitions stay literal",
     "git commit -m 'fix foo() alias and function source\nbun run lint exit 0'", "ALLOW"),
    ("a quoted argument holding a separator after a heavy command", "vitest \"--help;other\"", "DENY"),
    ("a heavy command chained after a commit", "git commit -m \"ok\" && vitest run", "DENY"),
    ("a heavy command on the next line", "git commit -m ok\nvitest run", "DENY"),
    ("a heavy command after a redirection", "echo x > out.txt; env CI=1 vitest run", "DENY"),
    ("a redirection target named like a heavy command", "echo x > vitest", "ALLOW"),
    # An expansion's output is unknown: it must not turn a word into an
    # inspection flag by vanishing from it.
    ("a substitution glued to an inspection flag",
     "npm --version$(printf${IFS}=false) run test", "DENY"),
    ("arithmetic glued to an inspection flag", "npm --version$((0)) run test", "DENY"),
    # A heredoc introducer named inside quotes is text, not a heredoc, so the
    # lines after it are still commands.
    ("a quoted backslash heredoc introducer before a command", "echo '<<\\EOF'\nvitest run", "DENY"),
    # Shell escape rules, not approximations of them.
    ("a double-quoted backslash before an ordinary letter", "npm \"--vers\\ion\" run test", "DENY"),
    ("a substitution inside arithmetic", "echo $(( $(\nvitest run\n) ))", "DENY"),
    ("an escaped dollar in a double-quoted delimiter", "cat <<\"E\\$OF\"\ntext\nE$OF\nvitest run", "DENY"),
    ("an escaped shell name reading a heredoc", "b\\as\\h <<\\EOF\nvitest run\nEOF", "DENY"),
    ("a quote-split shell name reading a heredoc", "ba''sh <<'EOF'\nvitest run\nEOF", "DENY"),
    ("a shift in quoted arithmetic is not a heredoc", "echo \"$((1 << 2))\"\nvitest run\n2", "DENY"),
    ("an arithmetic variable named like a heavy command", "echo \"$((vitest + 1))\"", "ALLOW"),
    ("a terminated double-quoted delimiter still strips its body",
     "cat > notes.md <<\"E\\$OF\"\nrun vitest run here\nE$OF", "ALLOW"),
    # ---- Third review (independent, of ce45786). Each group is one finding.
    # The behaviour behind each was observed on this Mac (npm 11.19.0, bun
    # 1.4.3, just 1.51.0, cargo 1.98.0): `npm run test --help` prints npm's
    # help while `npm run test -- --help` runs the script with --help,
    # `bun run test --help` runs the script, `bun test --help` prints the test
    # runner's help, `just test --dry-run` runs the recipe with an argument,
    # and `npm exec --help` / `bunx --help` list the launcher options. pnpm and
    # yarn are not installed here: their cases follow the same rule, failing
    # closed (flags after a script's name belong to the script).
    # Launchers: a version or scope on the package, and the options that take a
    # value. ----
    ("npx with a version suffix", "npx vitest@latest run", "DENY"),
    ("pnpm dlx with a version suffix", "pnpm dlx vitest@4 run", "DENY"),
    ("npx with a scoped, versioned package", "npx @scope/jest@29 --ci", "DENY"),
    ("bunx with a version suffix", "bunx tsc@5.4 --noEmit", "DENY"),
    ("npx --package names the package, not the program", "npx --package typescript tsc --noEmit", "DENY"),
    ("npx --package=", "npx --package=typescript tsc --noEmit", "DENY"),
    ("npx -p and a call string", "npx -p typescript -c 'tsc --noEmit'", "DENY"),
    ("npx --call", "npx --call 'vitest run'", "DENY"),
    ("npx --call=", "npx --call='vitest run'", "DENY"),
    ("a call string behind a wrapper", "npx -c 'timeout 60 tsc --noEmit'", "DENY"),
    ("a call string after an environment assignment", "npx -c 'CI=1 vitest run'", "DENY"),
    ("npx with workspace and package options", "npx -w web -p typescript tsc --noEmit", "DENY"),
    ("npm exec --package", "npm exec --package typescript -- tsc --noEmit", "DENY"),
    ("pnpm dlx --package", "pnpm dlx --package typescript tsc --noEmit", "DENY"),
    ("pnpm dlx in shell mode", "pnpm dlx -c 'tsc --noEmit'", "DENY"),
    ("yarn dlx -p", "yarn dlx -p typescript tsc -p .", "DENY"),
    ("bunx --package", "bunx --package typescript tsc --noEmit", "DENY"),
    ("bunx -p", "bunx -p typescript tsc --noEmit", "DENY"),
    ("bun x -p", "bun x -p typescript tsc --noEmit", "DENY"),
    ("npx versioned, queued", "membrake exec --label x -- npx vitest@latest run", "ALLOW"),
    ("npx --package, queued", "membrake exec --label x -- npx --package typescript tsc --noEmit", "ALLOW"),
    ("a call string, queued", "membrake exec --label x -- npx -p typescript -c 'tsc --noEmit'", "ALLOW"),
    ("a call string that queues itself", "npx -c 'membrake exec --label x -- tsc --noEmit'", "ALLOW"),
    ("the package is not the program", "npx --package vitest cowsay hi", "ALLOW"),
    ("a light call string", "npx -p typescript -c 'echo hi'", "ALLOW"),
    ("a light versioned program", "npx prettier@3 --check .", "ALLOW"),
    ("a versioned program asked for its version", "npx vitest@latest --version", "ALLOW"),
    ("a call string asked for its version", "npx -p typescript -c 'tsc --version'", "ALLOW"),
    # Cargo's and swift's own options take values; the subcommand follows them. ----
    ("cargo --config before the subcommand", "cargo --config net.offline=true test", "DENY"),
    ("cargo -Z before the subcommand", "cargo -Z unstable-options test", "DENY"),
    ("cargo --color before the subcommand", "cargo --color never build", "DENY"),
    ("cargo -C before the subcommand", "cargo -C app test", "DENY"),
    ("cargo --manifest-path before the subcommand", "cargo --manifest-path app/Cargo.toml check", "DENY"),
    ("cargo --target-dir before the subcommand", "cargo --target-dir out clippy", "DENY"),
    ("cargo --lockfile-path before the subcommand", "cargo --lockfile-path l.lock nextest run", "DENY"),
    ("cargo options after a toolchain selector", "cargo +nightly --config a=b test", "DENY"),
    ("cargo options, several", "cargo --color never --config a=b -Z x bench", "DENY"),
    ("cargo --config=", "cargo --config=net.offline=true test", "DENY"),
    ("cargo options and a non-heavy subcommand", "cargo --config net.offline=true metadata", "ALLOW"),
    ("cargo options and --version", "cargo --color never --version", "ALLOW"),
    ("cargo --config and a heavy subcommand, queued",
     "membrake exec --label x -- cargo --config net.offline=true test", "ALLOW"),
    ("swift --package-path before the subcommand", "swift --package-path app test", "DENY"),
    ("swift -c before the subcommand", "swift -c release build", "DENY"),
    # Heavy words anywhere in a recipe or script name, as a whole piece of it. ----
    ("just unit-test", "just unit-test", "DENY"),
    ("just release-build", "just release-build", "DENY"),
    ("just a path ending in verify", "just scripts/verify.sh", "DENY"),
    ("just ci_gate", "just ci_gate", "DENY"),
    ("pnpm run ci:build", "pnpm run ci:build", "DENY"),
    ("pnpm run test:unit", "pnpm run test:unit", "DENY"),
    ("npm run e2e:test", "npm run e2e:test", "DENY"),
    ("yarn run ci.lint", "yarn run ci.lint", "DENY"),
    # A second recipe cannot be told from a recipe argument without the
    # justfile, and arguments (`just wt fix/test-flakes`) are far more common:
    # only the first recipe is judged, membrake's brake covers the rest.
    ("a second recipe with a heavy piece", "just fmt unit-test", "ALLOW"),
    ("bun run ci:build, queued", "membrake exec --label x -- bun run ci:build", "ALLOW"),
    ("just latest", "just latest", "ALLOW"),
    ("just contest", "just contest", "ALLOW"),
    ("npm run rebuild-cache", "npm run rebuild-cache", "ALLOW"),
    ("pnpm run prebuilder:cache", "pnpm run prebuilder:cache", "ALLOW"),
    ("npm run attest", "npm run attest", "ALLOW"),
    # Inspection flags count only for the program being judged. ----
    ("cargo test with --help only for the test binary", "cargo test -- --help", "DENY"),
    ("cargo build with --version for rustc", "cargo build -- --version", "DENY"),
    ("cargo test --help before the --", "cargo test --help -- x", "ALLOW"),
    ("cargo --help before the subcommand", "cargo --help test", "ALLOW"),
    ("npx asked for its own version", "npx --version vitest", "ALLOW"),
    ("npx asked for its own help", "npx --help", "ALLOW"),
    ("npx asked for its version, with a package", "npx -p typescript --version", "ALLOW"),
    ("npm exec asked for its version", "npm exec --version vitest", "ALLOW"),
    ("pnpm dlx asked for help", "pnpm dlx --help vitest", "ALLOW"),
    ("npx vitest --help is vitest's help", "npx vitest --help", "ALLOW"),
    ("npx past -- forwards --help to the program", "npx vitest -- --help", "DENY"),
    ("tsc past -- is not inspecting", "tsc -p . -- --version", "DENY"),
    ("npm run test -- --help runs the script", "npm run test -- --help", "DENY"),
    ("npm test -- --help runs the script", "npm test -- --help", "DENY"),
    ("npm run test --help is npm's help", "npm run test --help", "ALLOW"),
    ("npm test --version is npm's version", "npm test --version", "ALLOW"),
    ("npm --help run test", "npm --help run test", "ALLOW"),
    ("bun run test --help runs the script", "bun run test --help", "DENY"),
    ("pnpm run test --help runs the script", "pnpm run test --help", "DENY"),
    ("pnpm test --help runs the script", "pnpm test --help", "DENY"),
    ("yarn run build --help runs the script", "yarn run build --help", "DENY"),
    ("bun test --help is the test runner's help", "bun test --help", "ALLOW"),
    ("bun run --help test", "bun run --help test", "ALLOW"),
    ("pnpm --help run test", "pnpm --help run test", "ALLOW"),
    ("npm --version exec vitest", "npm --version exec vitest", "ALLOW"),
    ("just verify --dry-run passes the flag to the recipe", "just verify --dry-run", "DENY"),
    ("just test -n passes the flag to the recipe", "just test -n", "DENY"),
    ("just test --help passes the flag to the recipe", "just test --help", "DENY"),
    ("just past -- runs what follows", "just -- test", "DENY"),
    ("just --version", "just --version", "ALLOW"),
    ("just --dry-run after a justfile option", "just --justfile ci/justfile --dry-run test", "ALLOW"),
    # ---- Fourth review (of 229f930). Observed with npm 11.19.0, bun 1.4.3 and
    # just 1.51.0: `npm exec --showConfig` is an unknown option and still runs
    # the program, `npm --version --version=false run test` runs the script,
    # `npm run -- test` and `npm -- run test` run `test`, `npm exec -c=tsc`
    # calls tsc, `just mode=release test` and `just --set mode release test`
    # run `test`. Only a launcher's real inspection flags (--version, -v,
    # --help, -h) ask it for anything. ----
    ("npm exec --showConfig is not inspection", "npm exec --showConfig -- vitest run", "DENY"),
    ("npx -V is not inspection", "npx -V vitest run", "DENY"),
    ("pnpm dlx --init is not inspection", "pnpm dlx --init vitest run", "DENY"),
    ("npm --showConfig before the subcommand", "npm --showConfig exec -- vitest run", "DENY"),
    ("npm run test --showConfig", "npm run test --showConfig", "DENY"),
    ("npx -v is the version", "npx -v", "ALLOW"),
    ("bunx -h is the help", "bunx -h", "ALLOW"),
    ("npm exec -h is the help", "npm exec -h vitest", "ALLOW"),
    ("npm run test -v is npm's version", "npm run test -v", "ALLOW"),
    ("npm --version cancelled by --version=false", "npm --version --version=false exec -- vitest run", "DENY"),
    ("npx --help cancelled by --help=false", "npx --help --help=false vitest run", "DENY"),
    ("npm exec --version cancelled inside the launcher",
     "npm exec --version --version=false -- vitest run", "DENY"),
    ("npm run test --version cancelled", "npm run test --version --version=false", "DENY"),
    ("npm exec --version=true is the version", "npm exec --version=true -- vitest run", "ALLOW"),
    ("npm exec --version=false, then --version again", "npm exec --version=false --version -- vitest run", "ALLOW"),
    ("a script name after --", "npm run -- test", "DENY"),
    ("the subcommand and script after --", "npm -- run test", "DENY"),
    ("a bare test after --", "npm -- test", "DENY"),
    ("pnpm run, then the script after --", "pnpm run -- test", "DENY"),
    ("a launcher subcommand after --", "npm -- exec vitest run", "DENY"),
    ("a light script name after --", "npm run -- dev", "ALLOW"),
    ("words after the script are its arguments", "npm run dev -- test", "ALLOW"),
    ("a flag after -- is not read as npm's", "npm run -- dev --version", "ALLOW"),
    ("just mode=release test", "just mode=release test", "DENY"),
    ("just with two overrides", "just a=1 b-2=x verify", "DENY"),
    ("just --set NAME VALUE", "just --set mode release test", "DENY"),
    ("just --set, then a justfile option", "just --set mode release --justfile ci/justfile build", "DENY"),
    ("just --set VALUE is not the recipe", "just --set mode release wt fix/test-flakes", "ALLOW"),
    ("just --set, then --dry-run", "just --set mode release --dry-run test", "ALLOW"),
    ("just override then a light recipe naming a test", "just mode=release wt fix/test-flakes", "ALLOW"),
    ("npm exec -c=", "npm exec -c=tsc", "DENY"),
    ("npx -c= with a quoted call string", "npx -c='vitest run'", "DENY"),
    ("pnpm dlx -c=", "pnpm dlx -c=tsc", "DENY"),
    ("npx -c= with a light call string", "npx -c='echo hi'", "ALLOW"),
    ("npx -c= queued", "membrake exec --label x -- npm exec -c=tsc", "ALLOW"),
    # ---- No command signals what it did not start (issue #270, 2026-11-11:
    # a script ran `kill -TERM -- -<group>` over every group it had looked
    # up). A process group, every process, or targets chosen by name or
    # pattern are denied wherever the command stands... ----
    ("a process group by number", "kill -TERM -- -12345", "DENY"),
    ("a process group from a variable", 'kill -TERM "-$pgid"', "DENY"),
    ("a process group with no signal named", "kill -- -$pgid", "DENY"),
    ("every process the user owns", "kill -9 -1", "DENY"),
    ("every process, with blanks around the number", "kill -TERM ' -1'", "DENY"),
    ("the incident's loop", 'for g in $groups; do kill -TERM -- "-$g" 2>/dev/null || true; done', "DENY"),
    ("after if", "if kill -KILL -$g; then echo gone; fi", "DENY"),
    ("inside a substitution", 'echo "$(kill -- -$g)"', "DENY"),
    ("behind command", "command kill -TERM -- -$g", "DENY"),
    ("behind builtin", "builtin kill -TERM -- -$g", "DENY"),
    ("the external program", "/bin/kill -TERM -- -$g", "DENY"),
    ("a group built from a substitution", "kill -TERM -- -$(cat group.txt)", "DENY"),
    ("groups through xargs", "ps -o pgid= -p 1 | xargs -I{} kill -- -{}", "DENY"),
    ("targets from a process search, piped", "pgrep -f vite | xargs kill", "DENY"),
    ("targets from a process search, piped with stderr", "pgrep -f vite |& xargs kill -9", "DENY"),
    ("targets from a process search, substituted", "kill $(pgrep -f vite)", "DENY"),
    ("targets from a process search, in backticks", "kill -9 `pgrep node`", "DENY"),
    ("the pattern terminator after do", "while true; do " + "p" + "kill -f vite; done", "DENY"),
    ("the name terminator in a subshell", f"( {KILL} LinearMouse )", "DENY"),
    ("the name terminator behind xargs", f"echo LinearMouse | xargs {KILL}", "DENY"),
    ("after a case label", 'case "$1" in stop) kill -TERM -- "-$g" ;; esac', "DENY"),
    ("on the line that opens a function", 'stop() { kill -TERM -- "-$g"; }', "DENY"),
    ("on the line that opens a function, keyword form",
     "function stop { " + "p" + "kill -f vite; }", "DENY"),
    # Reached any way but as the bare word, `kill` skips the shell guard's
    # function, and a target in a variable or on a pipe cannot be read here.
    ("by path, with a target the guard cannot read", "/bin/kill $target", "DENY"),
    ("behind command, with a target the guard cannot read", "command kill $target", "DENY"),
    ("behind builtin, with a target the guard cannot read", "builtin kill $target", "DENY"),
    ("behind env", "env kill 12345", "DENY"),
    ("behind the memory queue", "membrake exec --label x -- kill 12345", "DENY"),
    ("targets arriving on a pipe", "cat server.pid | xargs kill", "DENY"),
    ("computed groups arriving on a pipe", "ps -axo pgid= | sed 's/^/-/' | xargs kill -TERM --", "DENY"),
    # Found by the independent review of #271.
    # bash keeps reading options after the first signal (builtins/kill.def).
    ("a probe followed by a real signal", "kill -s 0 -s TERM -- -1", "DENY"),
    ("the short probe followed by a real signal", "kill -0 -s TERM -- -$g", "DENY"),
    ("builtin with its own --", "builtin -- kill -- -1", "DENY"),
    # The operand was a substitution, which left no word, so the name after it
    # was taken for the operand and the command read as restarting the Dock.
    ("a redirection whose operand is a substitution",
     f"/usr/bin/{KILL} >$(printf /dev/null) SomeApplication Dock", "DENY"),
    ("a process search nested twice", "kill $(echo $(pgrep -f vite))", "DENY"),
    ("a process search feeding a subshell", "pgrep -f vite | (xargs kill)", "DENY"),
    ("an unquoted heredoc that runs a group signal", "cat <<EOF\n$(/bin/kill -- -1)\nEOF", "DENY"),
    # Found by the re-review. In bash 3.2 `-s` and `-n` do not mark the signal
    # as given, so the number after them is a second signal.
    ("a probe, then a numeric signal", "kill -s 0 -15 -- -1", "DENY"),
    ("a numbered probe, then a numeric signal", "kill -n 0 -15 -- -1", "DENY"),
    ("a group probed without --", "kill -0 -$pgid", "DENY"),
    ("a case label in parentheses", "case x in (x) /bin/kill -- -1;; esac", "DENY"),
    ("a case inside a substitution", 'echo "$(case x in x) /bin/kill -- -1;; esac)"', "DENY"),
    ("the second arm of a case inside a substitution",
     "r=$(case $x in a) echo a;; b) kill -- -$g;; esac)", "DENY"),
    ("a trap handler", "trap '/bin/kill -- -1' EXIT", "DENY"),
    ("a trap handler that signals a group", "trap 'kill -- -$$' INT TERM", "DENY"),
    # Found by the third review pass.
    ("script strings nested past what is read", "eval " * 600 + "; /bin/kill -- -1", "DENY"),
    # Found by the fourth review pass: an escaped word is not a keyword.
    ("an escaped esac is a case pattern, not the end of the case",
     'echo "$(case esac in a) echo safe;; \\esac) /bin/kill -- -1;; esac)"', "DENY"),
    # Found by the fifth review pass: a quoted esac, ended by a blank.
    ("an escaped esac pattern followed by a blank",
     'echo "$(case esac in a) echo safe;; \\esac ) /bin/kill -- -1;; esac)"', "DENY"),
    ("a single-quoted esac pattern",
     "echo \"$(case esac in a) echo safe;; 'esac' ) /bin/kill -- -1;; esac)\"", "DENY"),
    ("a case closed inside a substitution, then a command",
     'echo "$(case x in x) echo safe;; esac)"; /bin/kill -- -1', "DENY"),
    ("a substitution in an argument inside a case arm",
     "case x in x) kill -$(printf TERM) -- -1;; esac", "DENY"),
    ("a case closed inside a substitution, then a pattern terminator",
     'echo "$(case x in x) echo safe;; esac)"; ' + "p" + "kill worker", "DENY"),
    # ---- ...and what delivers nothing, or reaches only what the command
    # started, passes. ----
    ("a search-fed probe", "kill -0 $(pgrep -f vite)", "ALLOW"),
    ("a search-fed probe behind xargs", "pgrep -f vite | xargs kill -0", "ALLOW"),
    ("asking what a name is", "command -v " + "p" + "kill", "ALLOW"),
    ("a word that starts with a terminator's name, inside a case arm",
     "case x in x) echo \"" + "p" + "kill$(printf '')\" worker;; esac", "ALLOW"),
    ("a case closed inside a substitution, then an ordinary command",
     'echo "$(case x in x) echo safe;; esac)"; echo done', "ALLOW"),
    ("a recorded id inside a function", 'stop() { kill "$pid"; }', "ALLOW"),
    ("a recorded id after a case label", 'case "$1" in stop) kill "$pid" ;; esac', "ALLOW"),
    ("a recorded id with an assignment in front", 'LC_ALL=C kill "$pid"', "ALLOW"),
    ("the probe by path", "/bin/kill -0 $pid", "ALLOW"),
    ("listing behind command", "command kill -l", "ALLOW"),
    ("braces that are data", "find . -name x -exec echo {} +", "ALLOW"),
    ("one recorded process id", 'kill "$pid"', "ALLOW"),
    ("one process id with a signal", "kill -TERM $pid", "ALLOW"),
    ("a signal held in a variable", "kill -$SIG $pid", "ALLOW"),
    ("several process ids", "kill -9 123 456", "ALLOW"),
    ("a job", "kill %1", "ALLOW"),
    ("the caller's own group", "kill 0", "ALLOW"),
    ("the probe signal on a group", "kill -0 -- -$pgid", "ALLOW"),
    ("the probe signal by name", "kill -s 0 -- -$pgid", "ALLOW"),
    ("a recorded id in a substitution beside a search", 'pgrep -f x | echo "$(kill $pid)"', "ALLOW"),
    ("a quoted brace is data", "printf '%s\\n' '{' " + "p" + "kill -f worker", "ALLOW"),
    ("a quoted brace before words that only name a script string",
     "printf '%s\\n' '{' bash -c 'echo hi'", "ALLOW"),
    ("a trap handler that stops a recorded id", "trap 'kill \"$pid\"' EXIT", "ALLOW"),
    ("resetting a trap", "trap - EXIT", "ALLOW"),
    ("listing signals", "kill -l", "ALLOW"),
    ("a process search on its own", "pgrep -fl vite", "ALLOW"),
    ("a process search, then an unrelated recorded id", "pgrep -f vite; kill $pid", "ALLOW"),
    ("a process search guarding a recorded id", "pgrep -f vite || kill $pid", "ALLOW"),
    ("naming the forbidden form in a message", 'echo "kill -- -1 is refused"', "ALLOW"),
    ("searching a script for the forbidden form", "grep -n 'kill -TERM -- -' cleanup.sh", "ALLOW"),
    (
        "a commit message that explains the rule",
        "git commit -F - <<'MSG'\nagents: never kill -- -$group or " + "p" + "kill -f\nMSG",
        "ALLOW",
    ),
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
    "heavy.sh": "#!/bin/bash\ntsc --noEmit\nvitest run\ncargo test\n",
    "benign.sh": ("#!/bin/bash\nOUT=/tmp/out\nls ~/Library/Caches\nmkdir -p \"$OUT\"\n"
                  "cat > notes.md <<'EOF'\nnever mkdir -p ~/Library/Caches/x\nEOF\n"
                  "node cli.js install chromium\nbash -c 'echo hi'\n"),
    # The 2026-11-11 incident's shape: groups looked up, then signalled, in a
    # file two scripts below the typed command.
    "interrupt.sh": "#!/bin/bash\nbash stop.sh\n",
    "stop.sh": "#!/bin/bash\n. ./tree.sh\nstop_tree\n",
    "tree.sh": ("stop_tree() {\n  for group in $(ps -axo pgid= | sort -u); do\n"
                "    kill -TERM -- \"-$group\" 2>/dev/null || true\n  done\n}\n"),
    "own-child.sh": "#!/bin/bash\nsleep 60 &\npid=$!\nkill \"$pid\"\nwait \"$pid\"\n",
    # A script's unquoted heredoc runs its substitutions.
    "heredoc.sh": "#!/bin/bash\ncat <<EOF\n$(/bin/kill -- -1)\nEOF\n",
    "heredoc-data.sh": "#!/bin/bash\ncat <<'EOF'\n$(/bin/kill -- -1)\nEOF\ncat <<EOF\ntoday is $(date)\nEOF\n",
    # Shell text handed to a shell or to eval inside a script (and, under
    # Codex, when typed) is read too.
    "string.sh": "#!/bin/bash\nsh -c '/bin/kill -- -1'\n",
    "eval.sh": "#!/bin/bash\neval kill -- -1\n",
    # What an argument-only edit to a script leaves behind (see EDIT_CASES).
    "pid-edited.sh": "#!/bin/bash\nkill -- -1\n",
    "huge.sh": "#!/bin/bash\n" + "# filler\n" * 150000 + "echo done\n",
    **{f"deep{n}.sh": f"#!/bin/bash\nbash deep{n + 1}.sh\n" for n in range(1, 10)},
    "deep10.sh": "#!/bin/bash\n/bin/echo bottom\n",
    **{f"sig{n}.sh": f"#!/bin/bash\nbash sig{n + 1}.sh\n" for n in range(1, 10)},
    "sig10.sh": "#!/bin/bash\nkill -- -1\n",
    **{f"many{n}.sh": f"#!/bin/bash\nbash many{n + 1}.sh\n" for n in range(70)},
    "many70.sh": "#!/bin/bash\necho bottom\n",
    # Five scripts of almost 1 MB each: each may be read, all may not.
    **{f"bulk{n}.sh": f"#!/bin/bash\nbash bulk{n + 1}.sh\n" + "# filler\n" * 110000 for n in range(5)},
    "bulk5.sh": "#!/bin/bash\necho bottom\n",
    ".envrc": "/usr/bin/" + "p" + "kill -f worker\n",
    "direct.sh": "/usr/bin/" + "p" + "kill -f worker\n",
    "string-plain.sh": "#!/bin/bash\nsh -c 'echo hi'\neval echo hi\n",
    "string-dashdash.sh": "#!/bin/bash\nbash -c -- '/bin/kill -- -1'\n",
    "eval-dashdash.sh": "#!/bin/bash\neval -- '/bin/kill -- -1'\n",
}
SCRIPT_CASES = [
    ("the incident: a probe script whose writes go through $DST", "bash {d}/probe.sh", "DENY"),
    ("a script under zsh -li", "zsh -li {d}/plain.sh", "DENY"),
    ("a sourced script", "source {d}/plain.sh", "DENY"),
    ("a dot-sourced script", ". {d}/plain.sh", "DENY"),
    ("a script under cpu-lock", "cpu-lock run --shared --wait 3600 --label x -- bash {d}/plain.sh", "DENY"),
    ("a script under membrake exec", "membrake exec --label x -- bash {d}/plain.sh", "DENY"),
    ("a script that runs heavy commands, queued as a whole",
     "membrake exec --label x -- bash {d}/heavy.sh", "ALLOW"),
    ("a script relative to the session directory", "bash plain.sh", "DENY"),
    ("a script another script runs", "bash {d}/outer.sh", "DENY"),
    ("a script sourced after a script string in a file", "bash {d}/after-string.sh", "DENY"),
    ("a shell-shebang script run by path", "{d}/exec.sh", "DENY"),
    ("a python script run by path is not shell", "{d}/exec.py", "ALLOW"),
    ("a script that reads, writes elsewhere, and names writes in data", "bash {d}/benign.sh", "ALLOW"),
    ("a script that does not exist", "bash {d}/missing.sh", "ALLOW"),
    ("a script path the guard cannot resolve", "bash \"$S/plain.sh\"", "ALLOW"),
    ("a script only shown, not run", "cat {d}/plain.sh", "ALLOW"),
    ("the incident: group signals two scripts below the typed command", "bash {d}/interrupt.sh", "DENY"),
    ("a script that stops the process id it recorded", "bash {d}/own-child.sh", "ALLOW"),
    ("an argument changed into a group, then run", "bash {d}/pid-edited.sh", "DENY"),
    # A known script the reader cannot read whole is refused, not passed.
    ("a script too large to read", "bash {d}/huge.sh", "DENY"),
    # Every script is followed however deep; only the number of different
    # scripts in one command is bounded.
    ("a chain of ten scripts, read to its end", "bash {d}/deep1.sh", "ALLOW"),
    ("a chain of ten scripts whose last signals a group", "bash {d}/sig1.sh", "DENY"),
    ("a command that runs more different scripts than are read", "bash {d}/many0.sh", "DENY"),
    ("scripts that hold more text in all than is read in time", "bash {d}/bulk0.sh", "DENY"),
    # A program run by path with a shell name and no shebang runs as shell.
    ("a .sh file with no shebang, run by path", "{d}/direct.sh", "DENY"),
    ("a .sh link to a file with no shebang and no shell name, run by path", "{d}/launch.sh", "DENY"),
    ("a shell startup file with no shebang, run by path", "{d}/.envrc", "DENY"),
    ("a script whose unquoted heredoc runs a group signal", "bash {d}/heredoc.sh", "DENY"),
    ("a script whose heredocs hold it as data, or substitute something else",
     "bash {d}/heredoc-data.sh", "ALLOW"),
    ("a script that hands a group signal to sh -c", "bash {d}/string.sh", "DENY"),
    ("a script that evals a group signal", "bash {d}/eval.sh", "DENY"),
    ("a script whose script strings are harmless", "bash {d}/string-plain.sh", "ALLOW"),
    ("a script string after --", "bash {d}/string-dashdash.sh", "DENY"),
    ("an eval string after --", "bash {d}/eval-dashdash.sh", "DENY"),
]

# ---- File edits that introduce signalling code (issue #270). Claude Code's
# Edit and Write tools and Codex's apply_patch; {d} is a temporary directory
# holding existing.sh, which already contains a group signal. ----
GROUP_SIGNAL = 'kill -TERM -- "-$group"'
PATTERN_CALL = "p" + 'kill -f vite'
EDIT_CASES = [
    # Whole files.
    ("writing a shell script that signals a group",
     {"file_path": "{d}/new.sh", "content": f"#!/bin/bash\n{GROUP_SIGNAL}\n"}, "DENY"),
    ("writing a shell script that stops a recorded id",
     {"file_path": "{d}/new.sh", "content": "#!/bin/bash\nsleep 60 &\npid=$!\nkill \"$pid\"\n"}, "ALLOW"),
    ("a shell script by shebang alone",
     {"file_path": "{d}/run", "content": f"#!/usr/bin/env bash\n{GROUP_SIGNAL}\n"}, "DENY"),
    ("a shell startup file with no shebang",
     {"file_path": "{d}/.zshenv", "content": f"{GROUP_SIGNAL}\n"}, "DENY"),
    ("the pattern terminator in a shell script",
     {"file_path": "{d}/new.zsh", "content": f"{PATTERN_CALL}\n"}, "DENY"),
    ("a shell script whose unquoted heredoc runs a group signal",
     {"file_path": "{d}/new.sh", "content": "cat <<EOF\n$(/bin/kill -- -1)\nEOF\n"}, "DENY"),
    ("rewriting a file with the group signal it already had",
     {"file_path": "{d}/existing.sh", "content": f"#!/bin/bash\n{GROUP_SIGNAL}\necho finished\n"}, "ALLOW"),
    ("rewriting a file of another language as a shell script",
     {"file_path": "{d}/tool", "content": f"#!/bin/bash\n{GROUP_SIGNAL}\n"}, "DENY"),
    ("prose that names the forbidden form",
     {"file_path": "{d}/notes.md", "content": f"Never write `{GROUP_SIGNAL}` or `{PATTERN_CALL}`.\n"}, "ALLOW"),
    ("a Nix module declaring an application restart",
     {"file_path": "{d}/mouse.nix", "content": f"run /usr/bin/{PATTERN_CALL} || true\n"}, "ALLOW"),
    ("a shell file too large to read",
     {"file_path": "{d}/big.sh", "content": "# filler\n" * 600000}, "DENY"),
    ("prose too large to read",
     {"file_path": "{d}/big.md", "content": "filler\n" * 800000}, "ALLOW"),
    # Replacements: each is judged against the text it replaces.
    ("an edit that adds a group signal",
     {"file_path": "{d}/existing.sh", "old_string": "echo done", "new_string": f"{GROUP_SIGNAL}\necho done"}, "DENY"),
    ("an edit that keeps a group signal the file already had",
     {"file_path": "{d}/existing.sh", "old_string": f"{GROUP_SIGNAL}\n", "new_string": f"{GROUP_SIGNAL}  # stop\n"}, "ALLOW"),
    ("an edit that adds a second copy",
     {"file_path": "{d}/existing.sh", "old_string": f"{GROUP_SIGNAL}\n",
      "new_string": f"{GROUP_SIGNAL}\n{GROUP_SIGNAL}\n"}, "DENY"),
    ("several edits, one adding a group signal",
     {"file_path": "{d}/existing.sh", "edits": [{"old_string": "a", "new_string": "b"},
                                                {"old_string": "echo done", "new_string": "kill -- -1"}]}, "DENY"),
    # The deliberate refusal: the text is judged without knowing where it lands.
    ("writing the form into a quoted message of a shell script",
     {"file_path": "{d}/message.sh", "old_string": "old", "new_string": "kill -- -1"}, "DENY"),
    # Two replacements are judged apart: their texts do not join into one.
    ("two harmless replacements that would read as one command if joined",
     {"file_path": "{d}/assign.sh", "edits": [{"old_string": "old-a", "new_string": "p\\"},
                                              {"old_string": "old-b", "new_string": "kill worker"}]}, "ALLOW"),
    # The stated limit: a change whose meaning depends on the text around it is
    # not seen here; the command hook reads the edited script when it runs
    # (see "an argument changed into a group, then run" below).
    ("changing only an argument into a group",
     {"file_path": "{d}/pid.sh", "old_string": "12345", "new_string": "-1"}, "ALLOW"),
    # Another language.
    ("another language shelling out to the pattern terminator",
     {"file_path": "{d}/stop.ts", "content": f'execSync("{PATTERN_CALL}");\n'}, "DENY"),
    ("an argument list starting with the name terminator",
     {"file_path": "{d}/stop.py", "content": f'subprocess.run(["{KILL}", name])\n'}, "DENY"),
    # Another language gets no interface-agent exception: rounds 9 to 12 each
    # found a way past one (an argument reader, then exact shapes that a
    # literal `+ [...]` or an adjacent string extends). A restart the code
    # already makes may stay; a new one belongs in a Nix activation entry.
    ("restarting an interface agent from code",
     {"file_path": "{d}/dock.py", "content": f'subprocess.run(["/usr/bin/{KILL}", "Dock"])\n'}, "DENY"),
    ("an interface agent list extended by another",
     {"file_path": "{d}/dock.py",
      "content": f'subprocess.run(["/usr/bin/{KILL}", "Dock"] + ["SomeApplication"])\n'}, "DENY"),
    ("an interface agent string extended by an adjacent one",
     {"file_path": "{d}/dock.py", "content": f'os.system("{KILL} Dock" " SomeApplication")\n'}, "DENY"),
    ("two interface agents in one list are not one of the exact shapes",
     {"file_path": "{d}/dock.py", "content": f'subprocess.run(["/usr/bin/{KILL}", "Dock", "Finder"])\n'}, "DENY"),
    # Deliberately refused: the line, comment included, is the call's identity;
    # reading where a comment starts let a changed target pass (round 14).
    ("a rewrite that changes only the comment on an existing restart",
     {"file_path": "{d}/commented.py",
      "content": f'subprocess.run(["/usr/bin/{KILL}", "Dock"])  # new comment\n'}, "DENY"),
    ("a changed target written after a hash inside a string",
     {"file_path": "{d}/hashed.py",
      "content": f'subprocess.run(["/usr/bin/{KILL}", """#SomeApplication\n""".lstrip("#").strip()])\n'}, "DENY"),
    ("a word in front of the terminator in a command string",
     {"file_path": "{d}/wrapped.py", "content": f'os.system("command {KILL} SomeApplication")\n'}, "DENY"),
    ("a path to the terminator that is not the usual one",
     {"file_path": "{d}/alias.py", "content": f'subprocess.run(["/usr/bin/./{KILL}", "SomeApplication"])\n'}, "DENY"),
    ("a rewrite that changes the target of an existing restart",
     {"file_path": "{d}/commented.py",
      "content": f'subprocess.run(["/usr/bin/{KILL}", "SomeApplication"])  # old comment\n'}, "DENY"),
    ("a computed target beside an interface agent",
     {"file_path": "{d}/dock.py", "content": f'subprocess.run(["/usr/bin/{KILL}", "Dock", chr(88)])\n'}, "DENY"),
    ("rewriting a file that already restarts an interface agent",
     {"file_path": "{d}/ui.py", "content": f'import os\nos.system("{KILL} Finder")\nprint(1)\n'}, "ALLOW"),
    ("two calls on one line, the second a pattern terminator",
     {"file_path": "{d}/stop.py",
      "content": f'run(["{KILL}", "Dock"]); run(["' + "p" + 'kill", "worker"])\n'}, "DENY"),
    ("an application beside a comment that mentions the Dock",
     {"file_path": "{d}/stop.py", "content": f'run(["{KILL}", "SomeApplication"])  # not Dock\n'}, "DENY"),
    ("a short replacement from one interface agent to another",
     {"file_path": "{d}/ui.py", "old_string": f"{KILL} Finder", "new_string": f"{KILL} Dock"}, "DENY"),
    ("an application after an inner bracket of the call",
     {"file_path": "{d}/agents.py",
      "content": f'subprocess.run(["/usr/bin/{KILL}", *["Dock"], ' + " " * 220 + '"SomeApplication"])\n'}, "DENY"),
    ("a name-based call whose arguments run past what is read gets no exception",
     {"file_path": "{d}/dock.py",
      "content": f'subprocess.run(["{KILL}", ' + '"Dock", ' * 40 + '"SomeApplication"])\n'}, "DENY"),
    ("a comment line that quotes the terminator",
     {"file_path": "{d}/stop.py", "content": '# Never run "' + "p" + 'kill -f worker" here\n'}, "ALLOW"),
    ("a slash comment in a C-family file",
     {"file_path": "{d}/stop.ts", "content": '// never execSync("' + "p" + 'kill -f worker")\n'}, "ALLOW"),
    ("a statement that starts with a decrement is not a comment",
     {"file_path": "{d}/stop.js", "content": '-- remaining; execSync("' + "p" + 'kill -f worker");\n'}, "DENY"),
    ("a statement that starts with a dereference is not a comment",
     {"file_path": "{d}/stop.go", "content": '* result = exec.Command("' + "p" + 'kill", "worker").Run()\n'}, "DENY"),
    ("a group signal by system call is not judged",
     {"file_path": "{d}/stop.py", "content": "os.killpg(process.pid, signal.SIGTERM)\n"}, "ALLOW"),
    # Codex patches.
    ("a patch that adds a shell script signalling a group",
     {"command": f"*** Begin Patch\n*** Add File: {{d}}/patched.sh\n+#!/bin/bash\n+{GROUP_SIGNAL}\n*** End Patch\n"}, "DENY"),
    ("a patch that moves a group signal the file already had",
     {"command": f"*** Begin Patch\n*** Update File: {{d}}/existing.sh\n@@\n-{GROUP_SIGNAL}\n+  {GROUP_SIGNAL}\n*** End Patch\n"}, "ALLOW"),
    ("a patch whose second file adds the pattern terminator",
     {"command": ("*** Begin Patch\n*** Update File: {d}/notes.md\n+hello\n"
                  f"*** Add File: {{d}}/two.sh\n+{PATTERN_CALL}\n*** End Patch\n")}, "DENY"),
    ("a patch to prose",
     {"command": f"*** Begin Patch\n*** Add File: {{d}}/notes.md\n+{GROUP_SIGNAL}\n*** End Patch\n"}, "ALLOW"),
    ("a patch that moves a text file to a shell script and adds a group signal",
     {"command": ("*** Begin Patch\n*** Update File: {d}/stop.txt\n*** Move to: {d}/moved.sh\n"
                  f"@@\n notes\n+{GROUP_SIGNAL}\n*** End Patch\n")}, "DENY"),
    ("a patch that makes a prose file a shell script with a group signal",
     {"command": ("*** Begin Patch\n*** Update File: {d}/becomes.md\n@@\n-# old\n+#!/bin/bash\n"
                  "@@\n-/bin/echo done\n+/bin/kill -- -1\n*** End Patch\n")}, "DENY"),
    ("a patch hunk that changes data in a heredoc to other data",
     {"command": ("*** Begin Patch\n*** Update File: {d}/existing.sh\n@@\n-echo done\n+echo finished\n"
                  "*** End Patch\n")}, "ALLOW"),
    # Found by the eighth review pass.
    ("a complete command written into a script whose interpreter line is long",
     {"file_path": "{d}/longbang", "old_string": "printf safe", "new_string": "/bin/kill -- -1"}, "DENY"),
    ("a complete command written into a large extensionless shell script",
     {"file_path": "{d}/bigrun", "old_string": "printf safe", "new_string": "/bin/kill -- -1"}, "DENY"),
    ("a shell script rewritten as Python with an ordinary variable",
     {"file_path": "{d}/was-shell.py", "content": "#!/usr/bin/env python3\n" + "p" + "kill = 1\nprint(1)\n"}, "ALLOW"),
    ("a source replacement that turns a quoted program into the pattern terminator",
     {"file_path": "{d}/run.py", "old_string": "printf", "new_string": "p" + "kill"}, "DENY"),
    ("the signal guard's own path, with no checkout named",
     {"file_path": "{d}/ai/shell-guard/kill-guard-test.sh", "content": f"{GROUP_SIGNAL}\n"}, "DENY"),
]


def in_directory(value, d):
    """`value` with {d} replaced in every string it holds."""
    if isinstance(value, str):
        return value.replace("{d}", d)
    if isinstance(value, list):
        return [in_directory(item, d) for item in value]
    if isinstance(value, dict):
        return {key: in_directory(item, d) for key, item in value.items()}
    return value


def hook(payload, *arguments):
    """The hook program's decision for a payload, run as the clients run it.

    A denial longer than one atomic pipe write (512 bytes) is dropped by the
    supervisor and the command runs, so such an output counts as ALLOW."""
    result = subprocess.run([sys.executable, GUARD, *arguments], input=json.dumps(payload),
                            capture_output=True, text=True, check=True)
    denied = '"permissionDecision":"deny"' in result.stdout and len(result.stdout.encode()) <= 512
    return "DENY" if denied else "ALLOW"


# ---- The program itself: it picks the rule from the tool's name, and Codex's
# hook (`--client codex`) drops the two rules that exist only because Claude
# Code stops to ask the owner. ----
HOOK_CASES = [
    ("a typed group signal", {"tool_name": "Bash", "tool_input": {"command": "kill -- -$g"}}, [], "DENY"),
    ("a typed group signal under Codex", {"tool_name": "Bash", "tool_input": {"command": "kill -- -$g"}},
     ["--client", "codex"], "DENY"),
    ("a script string under Claude Code", {"tool_name": "Bash", "tool_input": {"command": "bash -c 'echo hi'"}},
     [], "DENY"),
    ("a script string under Codex", {"tool_name": "Bash", "tool_input": {"command": "bash -c 'echo hi'"}},
     ["--client", "codex"], "ALLOW"),
    ("a machine change under Codex", {"tool_name": "Bash", "tool_input": {"command": "brew install some-cask"}},
     ["--client", "codex"], "DENY"),
    ("a Write that signals a group",
     {"tool_name": "Write", "cwd": "/nonexistent",
      "tool_input": {"file_path": "x.sh", "content": f"{GROUP_SIGNAL}\n"}}, [], "DENY"),
    ("a Codex patch that signals a group",
     {"tool_name": "apply_patch", "cwd": "/nonexistent",
      "tool_input": {"command": f"*** Begin Patch\n*** Add File: x.sh\n+{GROUP_SIGNAL}\n*** End Patch\n"}},
     ["--client", "codex"], "DENY"),
    ("a denial for a very long command still fits one pipe write",
     {"tool_name": "Bash", "tool_input": {"command": "brew install " + "some-cask " * 200}}, [], "DENY"),
    ("a denial for a very long group signal still fits one pipe write",
     {"tool_name": "Bash", "tool_input": {"command": "kill -TERM -- " + '"-$group" ' * 200}}, [], "DENY"),
    ("a denial whose text is not ASCII still fits one pipe write",
     {"tool_name": "Bash", "tool_input": {"command": "brew install " + "\u00e9" * 400}}, [], "DENY"),
    ("a denial for a group signal with non-ASCII text still fits one pipe write",
     {"tool_name": "Bash", "tool_input": {"command": "kill -- -1 " + "界" * 150}}, [], "DENY"),
    ("a lone surrogate in an edit to a large file is answered, not a crash",
     {"tool_name": "Write", "cwd": "/nonexistent",
      "tool_input": {"file_path": "big.md", "content": "\ud800" + "x" * (5 << 20)}}, [], "ALLOW"),
    ("a tool name that is not a string",
     {"tool_name": [], "tool_input": {"command": "kill -- -1"}}, [], "DENY"),
    ("script strings nested past what is read, under Codex",
     {"tool_name": "Bash", "tool_input": {"command": "eval " * 600 + "; /bin/kill -- -1"}},
     ["--client", "codex"], "DENY"),
    ("script strings nested a little, under Codex",
     {"tool_name": "Bash", "tool_input": {"command": "eval eval eval echo hi"}},
     ["--client", "codex"], "ALLOW"),
    ("a script string after --, under Codex",
     {"tool_name": "Bash", "tool_input": {"command": "eval -- '/bin/kill -- -1'"}},
     ["--client", "codex"], "DENY"),
    ("a script string that runs the pattern terminator, under Codex",
     {"tool_name": "Bash", "tool_input": {"command": "sh -c '" + "p" + "kill -f vite'"}},
     ["--client", "codex"], "DENY"),
    ("an unquoted heredoc that runs a group signal, under Codex",
     {"tool_name": "Bash", "tool_input": {"command": "cat <<EOF\n$(/bin/kill -- -1)\nEOF"}},
     ["--client", "codex"], "DENY"),
    ("a patch is not read as a typed command",
     {"tool_name": "apply_patch", "cwd": "/nonexistent",
      "tool_input": {"command": "*** Begin Patch\n*** Add File: notes.md\n+brew install some-cask\n*** End Patch\n"}},
     ["--client", "codex"], "ALLOW"),
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
        with open(os.path.join(d, "payload"), "w") as handle:
            handle.write("/usr/bin/" + "p" + "kill -f worker\n")
        os.symlink(os.path.join(d, "payload"), os.path.join(d, "launch.sh"))
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

    def commit(directory, *files):
        # A scratch repository's commit: no signing key belongs to a fixture.
        if files:
            subprocess.run(["git", "-C", directory, "add", *files], check=True, env=git_env)
        subprocess.run(["git", "-C", directory, "-c", "user.name=Example", "-c",
                        "user.email=example@example.invalid", "-c", "commit.gpgsign=false",
                        "commit", "-q", "--allow-empty", "-m", "fixture"], check=True, env=git_env)

    with tempfile.TemporaryDirectory() as d:
        subprocess.run(["git", "init", "-q", d], check=True, env=git_env)
        loader = os.path.join(d, "loader.sh")
        with open(loader, "w") as handle:
            handle.write("unset OP_CONNECT_TOKEN\nmkdir -p ~/Library/Caches/x\n")
        for name, expected, step in [
            ("an untracked script is read", "DENY", None),
            # Staging is a step any agent takes, so it earns no trust.
            ("a staged script is read", "DENY", "stage"),
            ("a committed script unchanged since is the repository's own", "ALLOW", "commit"),
            ("a committed script edited since is read", "DENY", "edit"),
            ("a committed script edited and staged since is read", "DENY", "stage"),
        ]:
            if step == "edit":
                with open(loader, "a") as handle:
                    handle.write("echo edited\n")
            elif step == "stage":
                subprocess.run(["git", "-C", d, "add", "loader.sh"], check=True, env=git_env)
            elif step == "commit":
                commit(d, "loader.sh")
            repository_cases += 1
            got = verdict("bash loader.sh", cwd=d)
            if got != expected:
                failures += 1
                print(f"FAIL  expected {expected:<5} got {got:<5}  {name}", file=sys.stderr)

        # The 2026-11-11 arrangement: the typed script and the one below it
        # are the repository's own and unchanged; the file they source is not.
        for file, text in {"interrupt.sh": "#!/bin/bash\nbash stop.sh\n",
                           "stop.sh": "#!/bin/bash\n. ./tree.sh\nstop_tree\n",
                           "tree.sh": "stop_tree() {\n  echo nothing to stop\n}\n"}.items():
            with open(os.path.join(d, file), "w") as handle:
                handle.write(text)
        commit(d, "interrupt.sh", "stop.sh", "tree.sh")
        for name, expected, leaf in [
            ("unchanged scripts that run unchanged scripts", "ALLOW", None),
            ("an edited script below two unchanged ones", "DENY",
             f"stop_tree() {{\n  for group in $(ps -axo pgid=); do {GROUP_SIGNAL}; done\n}}\n"),
        ]:
            if leaf:
                with open(os.path.join(d, "tree.sh"), "w") as handle:
                    handle.write(leaf)
            repository_cases += 1
            got = verdict("bash interrupt.sh", cwd=d)
            if got != expected:
                failures += 1
                print(f"FAIL  expected {expected:<5} got {got:<5}  {name}", file=sys.stderr)

        # An unchanged script that runs its edited child from inside an
        # unquoted heredoc's substitution.
        for file, text in {"report.sh": "#!/bin/bash\ncat <<EOF\n$(bash child.sh)\nEOF\n",
                           "child.sh": f"#!/bin/bash\n{GROUP_SIGNAL}\n"}.items():
            with open(os.path.join(d, file), "w") as handle:
                handle.write(text)
        commit(d, "report.sh")
        repository_cases += 1
        got = verdict("bash report.sh", cwd=d)
        if got != "DENY":
            failures += 1
            print(f"FAIL  expected DENY  got {got:<5}  an edited script run from an unchanged script's heredoc",
                  file=sys.stderr)

        # Rounds 9 and 10 found a committed script below a long chain, or a
        # script the chain had already passed through, hidden from a later
        # part of the same command. Every script is now read once and whole,
        # so where the command reaches it does not matter.
        chain = {f"w{n}.sh": f"#!/bin/bash\nbash w{n + 1}.sh\n" for n in range(8)}
        chain["w8.sh"] = "#!/bin/bash\nbash bridge.sh\n"
        chain["bridge.sh"] = "#!/bin/bash\nbash leaf.sh\n"
        chain["leaf.sh"] = "#!/bin/bash\n/bin/kill -- -1\n"
        # 800 references to one committed script, nine scripts down, must not
        # mean 800 checks of it: each is a pair of git commands, and a late
        # denial is dropped (13 s in the tenth pass).
        chain.update({f"f{n}.sh": f"#!/bin/bash\nbash f{n + 1}.sh\n" for n in range(8)})
        chain["f8.sh"] = "#!/bin/bash\n" + "bash bridge.sh\n" * 800
        for file, text in chain.items():
            with open(os.path.join(d, file), "w") as handle:
                handle.write(text)
        commit(d, "bridge.sh")
        for name, command in [("a committed script below a long chain, then run again", "bash w0.sh; bash bridge.sh"),
                              ("a script the chain already passed through, run again", "bash w0.sh; bash w8.sh"),
                              ("one committed script referenced 800 times, nine down", "bash f0.sh")]:
            repository_cases += 1
            started = time.monotonic()
            got = verdict(command, cwd=d)
            elapsed = time.monotonic() - started
            if got != "DENY" or elapsed > 5:
                failures += 1
                print(f"FAIL  expected DENY  got {got:<5} in {elapsed:.1f} s  {name}", file=sys.stderr)

        # The signal guard's own sources are exempt from the edit rule only in
        # the checkout the hook is told about, or a linked worktree of it.
        source = {"file_path": "ai/shell-guard/kill-guard-test.sh", "content": f"{GROUP_SIGNAL}\n"}
        linked = os.path.join(d, "linked")
        commit(d)
        subprocess.run(["git", "-C", d, "worktree", "add", "-q", linked], check=True, env=git_env)
        with tempfile.TemporaryDirectory() as elsewhere:
            for name, expected, cwd, checkout in [
                ("the guard's own test in the named checkout", "ALLOW", d, d),
                ("the guard's own test in a linked worktree of it", "ALLOW", linked, d),
                ("the same path in an unrelated directory", "DENY", elsewhere, d),
                ("the same path when another checkout is named", "DENY", d, elsewhere),
                ("the guard's own path, linked to a file outside the checkout", "DENY", "link", d),
            ]:
                if cwd == "link":
                    # ai/shell-guard/kill-guard-test.sh in the checkout is a
                    # link to a script elsewhere, which is what would be written.
                    os.makedirs(os.path.join(d, "ai", "shell-guard"))
                    os.symlink(os.path.join(elsewhere, "outside.sh"),
                               os.path.join(d, "ai", "shell-guard", "kill-guard-test.sh"))
                    cwd = d
                repository_cases += 1
                got = "DENY" if guard.edit_verdict(source, cwd, checkout) else "ALLOW"
                if got != expected:
                    failures += 1
                    print(f"FAIL  expected {expected:<5} got {got:<5}  {name}", file=sys.stderr)

    with tempfile.TemporaryDirectory() as d:
        for file, text in {
            "existing.sh": f"#!/bin/bash\n{GROUP_SIGNAL}\necho done\n",
            "pid.sh": "#!/bin/bash\nkill -- 12345\n",
            "message.sh": '#!/bin/bash\necho "old"\n',
            "assign.sh": "#!/bin/bash\na='old-a'\nb='old-b'\n",
            "tool": "#!/usr/bin/env python3\nprint(1)\n",
            "stop.txt": "notes\n",
            "becomes.md": "# old\n/bin/echo done\n",
            "hashed.py": f'subprocess.run(["/usr/bin/{KILL}", """#Dock\n""".lstrip("#").strip()])\n',
            "commented.py": f'subprocess.run(["/usr/bin/{KILL}", "Dock"])  # old comment\n',
            "ui.py": f'import os\nos.system("{KILL} Finder")\n',
            "longbang": "#!/" + "\u00e9" * 60 + "/bin/bash\nprintf safe\n",
            "bigrun": "#!/bin/bash\n#" + "x" * 4_194_304 + "\nprintf safe\n",
            "was-shell.py": "#!/bin/bash\necho old\n",
            "run.py": 'import subprocess\nsubprocess.run(["/usr/bin/printf", "worker"])\n',
        }.items():
            with open(os.path.join(d, file), "w") as handle:
                handle.write(text)
        for name, tool_input, expected in EDIT_CASES:
            got = "DENY" if guard.edit_verdict(in_directory(tool_input, d), d) else "ALLOW"
            if got != expected:
                failures += 1
                print(f"FAIL  expected {expected:<5} got {got:<5}  {name}", file=sys.stderr)
    for name, payload, arguments, expected in HOOK_CASES:
        got = hook(payload, *arguments)
        if got != expected:
            failures += 1
            print(f"FAIL  expected {expected:<5} got {got:<5}  {name}", file=sys.stderr)

    # A script read earlier in the command and gone by the time a later one is
    # read must not stop the later one being judged.
    with tempfile.TemporaryDirectory() as d:
        first, second = os.path.join(d, "first.sh"), os.path.join(d, "second.sh")
        with open(first, "w") as handle:
            handle.write("#!/bin/bash\necho hello\n")
        with open(second, "w") as handle:
            handle.write("#!/bin/bash\n/bin/kill -- -1\n")
        reader = guard.script_verdict

        def vanishing(path, kind, cwd, depth, seen):
            reason = reader(path, kind, cwd, depth, seen)
            if os.path.exists(first) and path.endswith("first.sh"):
                os.unlink(first)
            return reason

        guard.script_verdict = vanishing
        try:
            got = verdict(f"bash {first}; bash {second}", cwd=d)
        finally:
            guard.script_verdict = reader
        if got != "DENY":
            failures += 1
            print(f"FAIL  expected DENY  got {got:<5}  a later script after an earlier one vanished", file=sys.stderr)

    # The hook has ten seconds, and a denial that arrives late is dropped. A
    # line of 16,000 matches took 15 seconds when each looked ahead to the
    # line's end.
    many = "pkill = None\nnames = [" + ", ".join(["p" + "kill"] * 16000) + "]\n"
    started = time.monotonic()
    guard.edit_verdict({"file_path": "/nonexistent/run.py", "old_string": "pass", "new_string": many})
    elapsed = time.monotonic() - started
    if elapsed > 5:
        failures += 1
        print(f"FAIL  a source replacement with 16,000 matches took {elapsed:.1f} s", file=sys.stderr)

    # The two inputs round 12 found slow: many allowed calls before a refused
    # one, and a long run of blanks inside a call. Each must be answered in
    # time now that no allowed shape is searched for.
    for name, content in [
        ("32,000 interface-agent calls, then another", "commands = [" + ", ".join(
            [f'["/usr/bin/{KILL}", "Dock"]'] * 32000) + f']\nsubprocess.run(["/usr/bin/{KILL}", "SomeApplication"])\n'),
        ("60,000 blanks inside a name-based call", f'subprocess.run(["/usr/bin/{KILL}", "Dock"' + " " * 60000
         + ', "SomeApplication"])\n'),
    ]:
        started = time.monotonic()
        got = "DENY" if guard.edit_verdict({"file_path": "/nonexistent/run.py", "content": content}) else "ALLOW"
        elapsed = time.monotonic() - started
        if got != "DENY" or elapsed > 5:
            failures += 1
            print(f"FAIL  expected DENY  got {got:<5} in {elapsed:.1f} s  {name}", file=sys.stderr)

    # The whole answer, the denial's formatting included, must arrive in time:
    # a 960 KB refused line took 27 s to format in the thirteenth pass.
    long_line = "commands = [" + ", ".join([f'["/usr/bin/{KILL}", "Dock"]'] * 32000) + "]"
    started = time.monotonic()
    got = hook({"tool_name": "Write", "cwd": "/nonexistent",
                "tool_input": {"file_path": "run.py", "content": long_line + "\n"}})
    elapsed = time.monotonic() - started
    if got != "DENY" or elapsed > 5:
        failures += 1
        print(f"FAIL  expected DENY  got {got:<5} in {elapsed:.1f} s  a refused 960 KB line, end to end",
              file=sys.stderr)

    # An expiry that lands while the timer is being disarmed is still a
    # refusal, and the previous handler comes back. Modelled by delivering it
    # from the disarming call itself; no signal is sent.
    real_setitimer = guard.signal.setitimer

    def setitimer_that_expires(which, seconds, *rest):
        # The real timer is disarmed first, then the expiry that was already
        # pending is delivered, as the kernel would.
        result = real_setitimer(which, seconds, *rest)
        if seconds == 0:
            guard.signal.getsignal(guard.signal.SIGALRM)(guard.signal.SIGALRM, None)
        return result

    before = guard.signal.getsignal(guard.signal.SIGALRM)
    guard.signal.setitimer = setitimer_that_expires
    try:
        got = guard.answer({"tool_name": "Bash", "tool_input": {"command": "echo hi"}}, {})
    except BaseException as error:
        got = f"raised {type(error).__name__}"
    finally:
        guard.signal.setitimer = real_setitimer
    if (got != guard.TOO_SLOW or guard.signal.getsignal(guard.signal.SIGALRM) is not before
            or real_setitimer(guard.signal.ITIMER_REAL, 0) != (0.0, 0.0)):
        failures += 1
        print(f"FAIL  an expiry while disarming gave {got!r}", file=sys.stderr)

    # Whatever is slow, the answer is a refusal on time, not a late one.
    reader = guard.command_verdict
    guard.command_verdict = lambda *args, **kwargs: time.sleep(3)
    try:
        started = time.monotonic()
        got = guard.answer({"tool_name": "Bash", "tool_input": {"command": "echo hi"}}, {}, budget=0.5)
        elapsed = time.monotonic() - started
    finally:
        guard.command_verdict = reader
    if got != guard.TOO_SLOW or elapsed > 1.5:
        failures += 1
        print(f"FAIL  a reading past the budget gave {got!r} after {elapsed:.1f} s", file=sys.stderr)

    # Four million characters of the name-based word in one replacement: the
    # source rule must stay linear (13 s in the eleventh pass).
    many = "killall = None\nnames = [" + ", ".join(["kill" + "all"] * 450000) + "]\n"
    started = time.monotonic()
    guard.edit_verdict({"file_path": "/nonexistent/run.py", "old_string": "pass", "new_string": many})
    elapsed = time.monotonic() - started
    if elapsed > 5:
        failures += 1
        print(f"FAIL  a source replacement of four million characters took {elapsed:.1f} s", file=sys.stderr)

    total = len(CASES) + len(SCRIPT_CASES) + repository_cases + len(EDIT_CASES) + len(HOOK_CASES) + 8
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
