# Rebuild and activation

## Routine change

From the repository root with `NIX_CONFIG_LOCAL` set to the absolute ignored
`local.nix` path:

```sh
nix fmt
nix flake check --impure
nix eval --impure .#darwinConfigurations.example-mac.system
nix build --no-link --impure \
  .#darwinConfigurations.example-mac.system
```

Review the change and build result before activation. Then run:

```sh
./scripts/rebuild.sh
```

That is the activation path, for people and for agents alike. It sets
`NIX_CONFIG_LOCAL` and `SUDO_ASKPASS` and calls `sudo -A`, so the password is
collected in a native dialog rather than from a controlling terminal — which is
why it works from an editor-hosted or automated shell that has no TTY. It also
installs the repository's Git hooks before building.

Routine rebuilding never uses the `op` CLI, a service account or the desktop
application. Activation checks that the Connect environment
(`~/.config/op/connect.env`, mode 600) exists and fails loudly when it does not.
After a successful activation the script saves `local.nix` to 1Password through
Connect, as the Secure Note `nix-config local.nix` in the vault
named by `onePassword.vault`: created when missing, updated when it differs,
then read back (waiting up to 60 s for Connect to catch up) to verify the exact
text. Connect cannot write Document items, hence a Secure Note. A failure says
that activation succeeded but the backup is not current, and exits non-zero.

When `local.nix` declares `githubRunners`, the script then runs
`nix-config-github-runners-register`: every declared runner GitHub does not
list as online gets a registration token from the owner's `gh` login, stored
in 1Password through Connect and written to the token file the runners read;
it waits up to five minutes for all of them to come online, empties the token
file, and exits non-zero otherwise. A registration token expires after an
hour; a registered runner keeps its own credential in its state directory.

When `local.nix` declares `ciRunnerVms`, the script then runs
`nix-config-ci-runner-vm-register`. Each Linux VM has its own launchd agent,
which starts it at login (`modules/home/ci-runner-vm.nix`). For each VM, the
command waits up to thirty minutes for the guest to install Docker and the
runner, registers the runner with a token from the owner's `gh` login (passed
to the guest on standard input), and waits up to five minutes for GitHub to
list it online. A runner that is already online is left alone. A failure is
reported with the instance name (and individual runner name for a multi-runner
VM), the remaining runners and VMs are still attempted, and
the command exits non-zero if any VM failed. A GitHub listing error stops that
runner's attempt without replacing its registration.

Declare each isolated OrbStack Ubuntu machine by instance name. Omit
`ciRunnerVms` or leave it empty to declare no Linux CI machines.

```nix
ciRunnerVms = {
  ci-repo-a = {
    repository = "owner/repo-a";
    labels = [ "mac-vm-a" ];
    runners = 3;
  };
  ci-repo-b = {
    repository = "owner/repo-b";
    labels = [ "mac-vm-b" ];
    cpus = 8;
    memory = "16GiB";
  };
};
```

Each entry defaults to `name = <instance name>`, `labels = [ "mac-vm" ]`, and
`runners = 1`. The optional `cpus` and `memory` set per-machine limits. Specify
at least 1 GiB of memory in whole `GiB` or `MiB`. Each omitted limit shares
OrbStack's global capacity for that resource.
`runners` must be a positive integer. All expanded runner names must be
distinct across entries. Instance names start with an alphanumeric character
and contain only alphanumeric characters, dots, underscores or hyphens.
Each entry owns launchd label
`org.nix-community.home.ci-runner-vm-<instance>`, and log
`~/Library/Logs/ci-runner-vm-<instance>.log`. Guest files and credentials stay
on that instance's disk.

Each time the launchd agent starts, it checks isolation, applies changed
per-machine limits live, and provisions rootful Docker and the runner.
Activation sets OrbStack's global limits to the Mac's physical RAM and CPU
count. OrbStack releases unused memory back to macOS. If the global memory
limit changes, activation reports a pending OrbStack restart so active jobs
can finish.

With `runners = 3`, the example's first VM runs `ci-repo-a`, `ci-repo-a-2`
and `ci-repo-a-3`, all with the entry's labels. The first retains
`/opt/actions-runner` and `github-runner.service`; subsequent runners use
`/opt/actions-runner-2`, `github-runner-2.service`, and so on. Separate
installations keep registration credentials, updates and work directories
independent while all processes share the VM's rootful Docker and resource
limits. Increasing the count leaves an online first runner registered as-is.

Home Manager reconciles runner counts after setting up launchd agents. It
waits for the guest's initial provisioning and sends the desired runner
provisioning script over standard input. This applies count changes to an
existing machine while runner 1 stays running.
Guest reconciliation uses a lock so activation and registration
cannot install additional runners concurrently. Multi-runner registration
also reconciles before registering its runners. Count changes
leave the start script and launchd plist unchanged. Additional units
are enabled for subsequent boots.

Reducing the count stops and disables surplus runner units and prints each
actual registered name from its guest `.runner` file, for example
`warning: remove runner ci-repo-a-3 from owner/repo-a; it exceeds the declared runner count`.
Remove those names from that repository's GitHub Actions runners. This
deliberately reports removal rather than deleting GitHub registrations:
credentials and directories are retained, and no additional deletion token
or API permission is required. The warnings repeat while the retired guest
registration files remain. Lowering the count stops surplus units immediately,
so reduce it when those runners have finished their jobs. Reconciliation also
runs when the count is explicitly one or omitted, covering reductions back
to the default without changing the original single-runner generated files.

Do not hand-assemble the underlying command. It is recorded here only so the
script's final step is reviewable:

```sh
sudo -A --preserve-env=NIX_CONFIG_LOCAL,SUDO_ASKPASS \
  /run/current-system/sw/bin/darwin-rebuild switch --impure \
  --flake "path:$PWD#example-mac"
```

Activation changes the running Mac; the subsequent backup updates only its
configured recovery document.

## After activating

Activation succeeding is not the same as the change working. Home Manager
reports what it ran, not whether the application agreed.

Two failure modes have already cost hours here, both in `modules/home/mouse.nix`:

- **Activation ordering.** Entries declared `entryAfter [ "writeBoundary" ]` are
  unordered with respect to each other, including Home Manager's own
  `setDarwinDefaults`. An entry that restarts an application must depend on
  `setDarwinDefaults` by name, or it can relaunch the application before its
  preferences are written and leave a correct plist behind a stale process.
- **Assuming a setting means what it is called.** Check the application's
  source. LinearMouse's `whenAttentionNeeded`, for instance, means only that the
  battery indicator has a title — not that permissions or errors need attention.

## Lock updates

`flake.lock` pins every declared input, so nothing on the Mac advances on its
own. Updating is therefore an explicit act — but not a manual one. **You never
edit a version by hand**; `nix flake update` rewrites the lock for you, and the
pin is the receipt of what was pulled, not something you maintain.

The command is `nixup`, a shell alias for `scripts/update.sh` that forwards
its arguments; an application name is accepted wherever it is clearer than
the flake input behind it, and an unknown name is refused with the list of
both.

```sh
nixup                  # every input and every pin, then build and activate
nixup codex            # ChatGPT/Codex: the cask definition, plus where the installed app stands
nixup gcx              # gcx: the release tag in flake.nix and the Go vendor hash
nixup cli-proxy        # CLIProxyAPI and CPA Manager Plus: source releases and dependency hashes
nixup homebrew-cask    # any flake input, by its name in flake.nix
nixup --dry-run        # move the versions and build, do not activate
```

One kind of thing lives outside what `nix flake update` can move, and the
script moves it on a full run or by name: any input pinned to a release tag in
`flake.nix` — currently gcx — whose tag is rewritten to the latest GitHub
release and re-locked, with the Go vendor hash in `modules/home/gcx-pin.json`
refreshed when it changed (`nixup gcx`). A bare `nixup` therefore moves
everything this repository pins; nothing waits for a hand edit.

The Claude Code CLI is not moved by this script either: it is Anthropic's
self-updating native install behind a Nix launcher
(`modules/home/development.nix`), so it follows Anthropic's `latest` channel
in the background and `claude update` forces a check. `nixup claude` is
refused with that explanation.

ChatGPT.app, which carries the `codex` CLI, is not moved by this script at
all. It is a self-updating cask: Sparkle inside the app follows OpenAI's own
appcast, and the lock's cask definition only matters for a fresh install.
Every run prints the installed app and codex versions beside the lock's
definition and OpenAI's newest release; if the app is behind, launching it is
the update. Holding it at a version is not possible from this repository —
the app rewrites its Sparkle flags on every launch — which is why the earlier
pin was removed (see the `chatgpt` comment in `modules/darwin/homebrew.nix`).

The script prints which inputs actually moved, checks and builds, and activates
only if the build succeeds. A failure leaves the Mac untouched with the lock
change still in the working tree for inspection.

The equivalent by hand, if you want the steps separately:

```sh
nix flake update            # or: nix flake update <input> [<input>…]
nix flake check --impure
nix build --no-link --impure .#darwinConfigurations.example-mac.system
./scripts/rebuild.sh
```

Do not activate an unreviewed lock update.

### What a lock update does and does not reach

Three separate update channels feed this Mac, and only two are driven from here:

- **`nixpkgs`** — everything Nix and Home Manager install.
- **`homebrew-core` / `homebrew-cask`** — the cask *definitions*. These taps are
  flake inputs and `mutableTaps` is false, so `brew update` cannot move them;
  only a lock update can.
- **The applications' own updaters** — most declared casks carry Homebrew's
  `auto_updates` flag and update themselves entirely outside Nix. Two are
  deliberately not left to that: `karabiner-elements` is `greedy`, so a lock
  update does move it despite the flag, and `adobe-acrobat-pro` has its own
  updater disabled by `modules/darwin/adobe-updates.nix` while staying
  non-greedy, so nothing changes its version until someone asks for it.

Because `homebrew.onActivation.upgrade` is true, activation moves an installed
cask to whatever version the pinned tap defines. The cask that actually depends
on this is the one with no self-updater — currently `1password-cli` alone.
`claude-code` was in that list until it stopped being a cask; the CLI is now
Anthropic's self-updating native install, which no activation moves.

## Safety boundaries

- Homebrew reconciles declared casks with cleanup set to `"uninstall"`, never
  global `"zap"`.
- Home Manager fails on unmanaged-file collisions instead of overwriting them.
- macOS privacy approvals, account sign-ins, and application sessions remain
  interactive state.
