# Project launchers

`local.nix` declares a `projects` attribute set mapping a name to an absolute
directory. Each entry generates a Zsh function that changes into the directory
and starts Claude Code there with permissions bypassed, and an entry in the `p`
jump function, which changes directory without starting anything. `p` has
completion over the same names.

Project names are machine identity, not configuration. They live in the
git-ignored `local.nix` for the same reason the Git identity and the 1Password
item IDs do: this repository is public. `scripts/rebuild.sh` syncs `local.nix`
to 1Password after each successful activation, so the list survives a wiped
machine.

These are paths, not secrets, and they are written into the world-readable Nix
store as part of `.zshrc` — the same exposure the declared home directory
already has. That is the distinction to keep: the rule against secrets in Nix
expressions is about values that must never leave a vault, not about names that
must stay out of a public Git history. A token or a private URL still does not
belong here.

A generated function shadows any command of the same name, so `projects.nix`
asserts at evaluation time that no name collides with a shell builtin or a
command this configuration depends on, and that every name is a valid shell
function name. A project called `git` fails the build instead of silently
breaking the shell.

`claude` is invoked by name inside the functions, never by store path. The
Home Manager claude-code module wraps the package with `--plugin-dir`, and
`secrets.nix` may replace `bin/claude` with a 1Password launcher; a hard-coded
store path would bypass whichever is active.

## Why these are not the alias collection terminal.md rejects

`terminal.md` says project commands belong in a project's own `justfile`, not in
a global alias collection that can hide deploy or destructive context. That rule
still holds and these do not breach it. A launcher changes directory and starts
an agent; it wraps no build, deploy, or destructive operation, and it hides no
flags from a command that would otherwise show them. The moment an entry here
starts meaning "and also run the deploy", it belongs in that project's
`justfile` instead.

## Bypassed permissions

`claudeSettings` sets `permissions.defaultMode = "bypassPermissions"`, so every
session starts with prompts off, not only the launchers. `cc`, `ccr`, and `ccc`
are declared in `modules/home/ai/default.nix` beside the client they launch, and
still pass `--dangerously-skip-permissions` explicitly. That is not redundant:
the user settings file is the lowest-precedence scope, so a repository declaring
its own `permissions.defaultMode` overrides it, while a command-line argument
outranks project settings.

The accepted cost is that invocations nobody typed also bypass — a background
`claude -p` started by a hook or script gets the same treatment. Those callers
should pass `--permission-mode default` explicitly.

The `nix-only-guard` PreToolUse hook still runs and still denies under this
mode, so bypassing removes the interactive prompts, not the hook. Explicit `ask`
and `deny` rules survive too, and removals targeting `~` or `/` still prompt.

What it does not survive is prompt injection, which is why the guard — not the
prompt — is the thing actually protecting this machine. Anything that weakens
`nix-only-guard` weakens every one of these launchers at once.
