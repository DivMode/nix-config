# New Mac setup

This is the complete bootstrap procedure. The public repository contains no
personal or machine identity.

## Prerequisites

1. Install Apple Command Line Tools with `xcode-select --install` and complete
   Apple's prompts.
2. Install Nix and clone this repository. Do not install 1Password manually;
   the first Nix switch installs it through declarative Homebrew.
3. Open the repository directory in a terminal.

Full Xcode is not required unless an Apple-platform project needs it.

## Recommended automated path

Run:

```sh
./scripts/setup-mac.sh
```

The wizard detects non-secret Mac fields, creates safe bootstrap placeholders,
runs the first switch, and pauses for 1Password sign-in. It then **restores
the ignored `local.nix` from 1Password**: each host's canonical copy lives as
a Document item titled `nix-config local.nix <LocalHostName>`, validated
against the detected account/hostname/architecture before it is trusted. On a
wiped machine that already has a stored copy, no identity or deploy wiring is
ever retyped — the Connect host, 1Password item IDs, and AWS profiles all come
back with the restore, and the final switch is the last step.

Only a brand-new host (no stored copy, or a mismatched one) continues into the
interactive stage: choose the signing key and any additional SSH keys, the
wizard writes ignored `local.nix` and uploads it as the host's stored copy for
next time. Private keys never leave 1Password either way.

`scripts/rebuild.sh` keeps the stored copy current: after every successful
activation it compares `local.nix` against the Document item and re-uploads it
when they differ.

## Manual fallback

The following steps describe what the wizard automates.

### Create the local host input

Copy the public template:

```sh
cp local.example.nix local.nix
```

For the first pass, fill only these Mac fields:

- `user`: short macOS account name;
- `hostName`: desired Mac hostname;
- `system`: `aarch64-darwin` for Apple Silicon or `x86_64-darwin` for Intel;
- `homeDirectory`: absolute `/Users/<account>` path;

Leave the public Git and 1Password placeholders intact until the first switch
has installed 1Password. They are structurally valid bootstrap values, not
credentials and not a usable signing identity.

After installing and signing in to 1Password, replace:

- `git.name`: public author name embedded in commits;
- `git.email`: Git-host-verified address embedded in commits;
- `git.signingKey`: Ed25519 SSH **public** key used for signing;
- `onePassword.sshAgentKeyIds`: ordered item IDs for every SSH key this Mac
  should offer, with the Git signing/authentication key first.

The email is not secret: Git embeds it in every commit and local Nix evaluation
places it in the Nix store. Use a GitHub privacy address if public commits must
not expose a personal mailbox. Its numeric prefix is the GitHub account ID, not
a key identifier.

In 1Password, copy only the public key from the existing SSH Key item. Never put
an SSH private key, password, token, recovery value, or private repository detail
in `local.nix` or another Nix expression.

For each intended SSH key, copy its item UUID from 1Password and add it to
`onePassword.sshAgentKeyIds`. IDs keep private item and vault names out of the
public repository. The order is also the order in which 1Password offers keys to
SSH servers.

Keep the file ignored and expose its absolute path to Nix:

```sh
export NIX_CONFIG_LOCAL="$PWD/local.nix"
```

Commands require `--impure` because a flake intentionally excludes ignored
files. Evaluation validates every required field and accepts only an Ed25519
public signing key.

### Validate

Run the validation and non-activating build in
[`../operations/rebuild.md`](../operations/rebuild.md). Never switch a generation
whose lock, format, checks, evaluation, and build have not succeeded and been
reviewed.

### First generation

Before the first nix-darwin generation, `darwin-rebuild` and 1Password are not
installed. Use
the official nix-darwin 26.05 bootstrap command and pass this repository's flake:

```sh
sudo env \
  NIX_CONFIG_LOCAL="$NIX_CONFIG_LOCAL" \
  NIX_CONFIG="extra-experimental-features = nix-command flakes" \
  /nix/var/nix/profiles/default/bin/nix \
  run nix-darwin/nix-darwin-26.05#darwin-rebuild -- \
  switch --impure --flake "path:$PWD#example-mac"
```

The first generation installs 1Password and its CLI. Open 1Password, sign in,
enable its SSH agent and CLI integration, then replace the bootstrap Git/SSH
placeholders in `local.nix`. Run the routine switch in the operations guide to
apply the final identity. This distinction follows the
[official nix-darwin installation instructions](https://github.com/nix-darwin/nix-darwin#step-2-installing-nix-darwin).

### 1Password and Git

1. Enable **1Password > Settings > Developer > Use the SSH agent**.
2. Put the intended SSH Key item IDs in `local.nix`; the generated 1Password
   agent configuration makes keys from non-default vaults eligible.
3. Ensure the same public key is registered as an SSH signing key with the Git
   host.
4. After activation, inspect the generated Git settings:

   ```sh
   git config --global --get-regexp '^(user|gpg|commit|tag)\.'
   ```

5. Create a local signed test commit before publishing anything.

Home Manager configures SSH-format commit and tag signing through 1Password's
`op-ssh-sign`; the private key remains inside 1Password.

### Manual checklist

- Complete the [Karabiner first run](../../modules/home/karabiner.md#first-run),
  then run `scripts/check-karabiner.sh` and confirm every line reports `ok`.
  Grant Accessibility to **Karabiner-Core-Service**, not to
  `Karabiner-Elements.app` — see the linked section for why that distinction
  matters.
- Complete the [LinearMouse first run](../../modules/home/mouse.md).
- Sign in to 1Password and enable its SSH agent as described above.

These are protected macOS or application controls and cannot safely be approved
by Nix. TCC grants are per-machine and never survive a fresh install; there is
no supported way to script them without enrolling the Mac in an MDM, so expect
to grant each one exactly once.

Do not diagnose a keyboard problem by reading logs — run
`scripts/check-karabiner.sh`. It distinguishes a missing permission from an
unwritable configuration directory, which produce identical symptoms.
