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
why it works from an editor-hosted or automated shell that has no TTY. Nothing
before its final line changes the Mac.

Do not hand-assemble the underlying command. It is recorded here only so the
script's final step is reviewable:

```sh
sudo env NIX_CONFIG_LOCAL="$NIX_CONFIG_LOCAL" \
  /run/current-system/sw/bin/darwin-rebuild switch --impure \
  --flake "path:$PWD#example-mac"
```

Activation is the only step above that changes the running Mac.

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

```sh
./scripts/update.sh                  # every input, then build and activate
./scripts/update.sh homebrew-cask    # only the Homebrew casks
./scripts/update.sh --dry-run        # move the lock and build, do not activate
```

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
  `auto_updates` flag and update themselves entirely outside Nix.

Because `homebrew.onActivation.upgrade` is true, activation moves an installed
cask to whatever version the pinned tap defines. The casks that actually depend
on this are the ones with no self-updater — currently `claude-code` and
`1password-cli`.

## Safety boundaries

- Homebrew reconciles declared casks with cleanup set to `"uninstall"`, never
  global `"zap"`.
- Home Manager fails on unmanaged-file collisions instead of overwriting them.
- macOS privacy approvals, account sign-ins, and application sessions remain
  interactive state.
