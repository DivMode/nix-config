# nix-config

A public, multi-host Nix configuration for reproducible Macs today and NixOS
servers later.

It combines Nix flakes, nix-darwin, Home Manager, and declarative Homebrew.
Nix owns portable tools and user configuration; Homebrew owns native/vendor
macOS applications; 1Password owns secrets and SSH private keys. There is no
chezmoi layer.

> Status: activated and verified on one Apple Silicon Mac. New hosts must still
> complete validation and the interactive post-install checklist.

## What it manages

- macOS defaults, Dock contents, fonts, and native applications;
- Nix-managed Zsh, Starship, Git, developer tools, and Herdr;
- Karabiner keyboard rules and LinearMouse configuration through Home Manager;
- public-safe Git identity inputs and 1Password references;
- dormant shared AI renderers that remain disabled in the basic profile.

The precise ownership model is documented in
[`docs/architecture.md`](docs/architecture.md). The canonical package lists are
the Nix modules themselves.

## Repository layout

```text
.
├── ai/                    # Shared, currently dormant AI sources
├── docs/                  # Setup, operations, architecture, and research
├── hosts/                 # Host compositions
├── modules/
│   ├── darwin/            # macOS, Nix, Dock, fonts, and Homebrew
│   └── home/              # Home Manager user configuration
├── profiles/              # Reusable user profiles
├── secrets/               # 1Password and secret-boundary reference
├── flake.nix
└── local.example.nix      # Generic, public host-input template
```

## Quick start

The repeatable setup wizard handles the two-pass bootstrap:

```sh
./scripts/setup-mac.sh
```

The first pass installs 1Password and every other declared application. After
sign-in, the wizard **restores the ignored `local.nix` from 1Password** — a
Document item titled `nix-config local.nix <LocalHostName>` — and applies the
final identity. Nothing is retyped on a wiped machine: the host's deploy
wiring (the Connect host, 1Password item IDs, AWS profiles) comes back with
the restore, and `scripts/rebuild.sh` re-uploads the stored copy after any
activation whose `local.nix` changed. Only a **brand-new host** (no stored
copy) falls through to the interactive identity stage, which writes
`local.nix` and uploads it for next time. The complete manual fallback is in
[`docs/setup/new-mac.md`](docs/setup/new-mac.md).

The manual short path is:

1. Install Nix and clone the repository. Do not install 1Password manually.
2. Create the ignored host input. For the first pass, replace only the Mac
   account, hostname, architecture, and home-directory placeholders; leave the
   public Git/1Password bootstrap placeholders until Nix installs 1Password:

   ```sh
   cp local.example.nix local.nix
   export NIX_CONFIG_LOCAL="$PWD/local.nix"
   ```

3. Validate and build without changing the Mac:

   ```sh
   nix fmt
   nix flake check --impure
   nix build --no-link --impure \
     .#darwinConfigurations.example-mac.system
   ```

4. Review the result. On a new Mac, use the first-generation command in the
   [setup guide](docs/setup/new-mac.md#first-generation). On an existing
   nix-darwin host, switch deliberately:

   ```sh
   sudo env NIX_CONFIG_LOCAL="$NIX_CONFIG_LOCAL" \
     /run/current-system/sw/bin/darwin-rebuild switch --impure \
     --flake "path:$PWD#example-mac"
   ```

Do not put passwords, tokens, SSH private keys, recovery material, or private
repository information in `local.nix`. The ignored file contains host identity,
public Git metadata, and an SSH **public** signing key only.

## Apply changes

The everyday operations are:

```sh
nix flake check --impure
nix build --no-link --impure .#darwinConfigurations.example-mac.system
./scripts/rebuild.sh
```

`scripts/rebuild.sh` is the activation path. It builds first, then activates
without a password: a declared sudoers rule (`modules/darwin/sudo.nix`) allows
exactly the `darwin-rebuild` activation command for this account, so rebuilds
run unattended from any shell. Anything else under sudo still prompts — the
askpass dialog remains as the fallback (and covers the one first switch on a
wiped machine, before the rule exists). Do not hand-assemble the
`darwin-rebuild switch` command.

To move the pinned inputs forward and apply the result in one step:

```sh
./scripts/update.sh                  # every input
./scripts/update.sh homebrew-cask    # only the Homebrew casks
```

Versions live in `flake.lock` and are never edited by hand.

Format and inspect changes before switching. Lock updates and detailed operating
procedures are in [`docs/operations/rebuild.md`](docs/operations/rebuild.md).

## Post-install checklist

macOS and third-party security controls require these one-time interactive steps:

- complete 1Password and Git setup;
- complete the Karabiner and LinearMouse approvals;
- disable Raycast's native Hyper Key;
- verify Git identity and a signed test commit before publishing;
- confirm the declared Dock, Finder, keyboard, terminal, and mouse behavior.

Nix does not bypass macOS privacy controls or manufacture authentication
sessions.

## State boundary

The repository rebuilds declared packages and configuration. It does not rebuild
chat history, browser profiles, application databases, authentication sessions,
Keychain contents, caches, or mutable terminal sessions. See
[`docs/state-boundary.md`](docs/state-boundary.md).

## Documentation

- [New Mac setup](docs/setup/new-mac.md)
- [Rebuild and activation](docs/operations/rebuild.md)
- [Architecture and ownership](docs/architecture.md)
- [Mutable-state boundary](docs/state-boundary.md)
- [macOS and Homebrew](modules/darwin/README.md)
- [Karabiner keyboard](modules/home/karabiner.md)
- [Application launcher hotkeys](modules/home/launchers.md)
- [Terminal and Zsh](modules/home/terminal.md)
- [Developer tools](modules/home/development.md)
- [Mouse](modules/home/mouse.md)
- [AI source model](ai/README.md)
- [1Password and secrets](secrets/README.md)
- [Research notes](docs/research/)

## Later milestones

1. Validate Intel Darwin if that platform is added.
2. Observe exact MX button identifiers before adding button mappings.
3. Add merge-safe adapters before enabling mutable AI client configuration.
4. Add NixOS host modules when the first server is defined.
