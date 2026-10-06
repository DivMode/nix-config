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

### New Mac

1. In Setup Assistant, create the account with the same short name as the old
   Mac (the computer name can be anything; it is kept).
2. Plug in the external `Data` drive and join the network the 1Password Connect
   server is on.
3. In Terminal, run:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/DivMode/nix-config/main/scripts/bootstrap.sh | bash
   ```

4. Type your Mac password once. When asked, paste the two Connect values, both
   in 1Password (on a phone is fine; copy there, then Cmd-V on the Mac):
   - **Connect URL:** open the Secure Note `nix-config local.nix <old Mac's name>`
     and copy the value of `onePassword.connectHost` (an `http://…:8091` address).
   - **Connect token:** search 1Password for "Connect", open the Connect
     server's credentials item, and copy its `access-token` field.
5. Grant the Karabiner and LinearMouse permissions it lists at the end.

It installs the Command Line Tools and Nix, clones this repository, and runs the
setup wizard, which asks for the 1Password Connect URL and token (and, when
1Password holds several Macs, which one this Mac replaces), restores
`local.nix` from its 1Password Secure Note (keeping this Mac's own name), and
applies everything. Details: [`docs/setup/new-mac.md`](docs/setup/new-mac.md).

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
without a password: declared sudoers rules (`modules/darwin/sudo.nix`) allow
exactly the `darwin-rebuild` activation command for this account, plus
`/usr/sbin/installer` and `/usr/sbin/pkgutil` for the privileged installers
Homebrew nests inside `brew bundle`, so rebuilds run unattended from any shell.
Anything else under sudo still prompts — the askpass dialog remains as the
fallback (and covers the one first switch on a wiped machine, before the rules
exist). Do not hand-assemble the `darwin-rebuild switch` command.

To move the pinned inputs forward and apply the result in one step, type
`nixup` (a shell alias for `scripts/update.sh`; arguments pass through):

```sh
nixup                  # every input and every pin
nixup codex            # ChatGPT/Codex: the cask definition, and where the app stands
nixup gcx              # gcx: its release tag and Go vendor hash
nixup homebrew-cask    # any flake input, by its name
```

Versions live in `flake.lock`; the script moves it and it is not edited by
hand. Two things update themselves instead: Claude Code, whose native install
keeps itself current in the background (`claude update` forces it), and
ChatGPT.app, which carries the `codex` CLI — launching it is the update, and
the script reports where it stands.

Format and inspect changes before switching. Lock updates and detailed operating
procedures are in [`docs/operations/rebuild.md`](docs/operations/rebuild.md).

## Post-install checklist

macOS and third-party security controls require these one-time interactive steps:

- nothing for 1Password: everything reads it through Connect, set up by the wizard;
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
- [Local CLIProxyAPI and CPA Manager Plus](docs/operations/cli-proxy.md)
- [Architecture and ownership](docs/architecture.md)
- [Orchestration architecture](docs/orchestration-architecture.md)
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
