# New Mac setup

This documents bootstrap and its current limitations. The public repository
contains no personal or machine identity.

## Prerequisites

1. Install Apple Command Line Tools with `xcode-select --install` and complete
   Apple's prompts.
2. Install Nix and clone this repository. Do not install 1Password manually;
   the first Nix switch installs it through declarative Homebrew.
3. Open the repository directory in a terminal.

Full Xcode is not required unless an Apple-platform project needs it.

## Setup wizard

Nothing in setup or routine use touches the 1Password desktop application, the
`op` CLI or a service account. The one credential a new Mac receives by hand is
the **1Password Connect URL and token**; everything that reads 1Password
afterwards (Git signing and push, AWS, the network share, the `local.nix`
restore) uses Connect, and a Connect failure stops with the reason instead of
falling back.

Before running the wizard, have ready:

- this Mac on the same network as the Connect server (or a VPN to it);
- the Connect URL and access token (from 1Password on the web or a phone);
- either the old Mac's `local.nix` (copy it into the clone, with `hostName`
  changed to the new Mac's `scutil --get LocalHostName`), or the new Mac
  renamed to the old Mac's local hostname so the stored copy matches.

Then run:

```sh
./scripts/setup-mac.sh
```

The wizard detects the Mac, runs an install-only first switch, writes the
Connect URL and token to `~/.config/op/connect.env` (mode 600; the token is
never written to `.setup-mac.env`), checks that Connect answers, restores
`local.nix` from the Document item `nix-config local.nix <LocalHostName>`
through Connect (unless a complete matching `local.nix` is already present),
seeds the network-share password from Connect, and applies the final switch.
Every routine rebuild then fails loudly if `connect.env` is missing.

`scripts/rebuild.sh` no longer uploads `local.nix` to 1Password. Keep the
stored Document current by hand after editing `local.nix`.

## Manual fallback

The steps below also cover a brand-new host without a complete stored
`local.nix`. The wizard's identity writer currently omits required download and
credential configuration fields; it is not a complete new-host configurator.
Prepare a complete input from `local.example.nix` before the first build, and
retain those fields when setting the final identity. Restoring a complete
existing host document avoids that limitation.

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
- `git.signingKeyReference`: reference to that same item's private key, ending
  in `/private key?ssh-format=openssh`, readable by the Connect token;
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

Older host inputs and restored backups must have `git.signingKeyReference`
added before rebuilding. Preserve every existing field; do not replace the
host input with bootstrap placeholders. The reference contains only item
metadata, never the token or private key. Update the stored `local.nix`
Document in 1Password by hand after editing; rebuilds no longer upload it.

GitHub SSH fetches and pushes use the same key, read from Connect, through the
declarative Git transport. Register its public key for authentication on the
intended GitHub account as well as for signing. The transport accepts only
GitHub repository fetch/push commands, requires a trusted GitHub host key in
OpenSSH's known-hosts file, and disables desktop-agent and password fallback.
Other SSH Git hosts fail closed until a declarative transport is configured.
Ordinary SSH outside Git retains its existing configuration.

### Validate

Run the validation and non-activating build in
[`../operations/rebuild.md`](../operations/rebuild.md). For the human first-time
installation only, set `NIX_CONFIG_SETUP_BOOTSTRAP=1` during evaluation/build
to defer credential maintenance until sign-in. Never switch a generation
whose lock, format, checks, evaluation, and build have not succeeded and been
reviewed.

### First generation

Before the first nix-darwin generation, `darwin-rebuild` and 1Password are not
installed. Use
the official nix-darwin 26.05 bootstrap command and pass this repository's flake:

```sh
sudo env \
  NIX_CONFIG_LOCAL="$NIX_CONFIG_LOCAL" \
  NIX_CONFIG_SETUP_BOOTSTRAP=1 \
  NIX_CONFIG="extra-experimental-features = nix-command flakes" \
  /nix/var/nix/profiles/default/bin/nix \
  run nix-darwin/nix-darwin-26.05#darwin-rebuild -- \
  switch --impure --flake "path:$PWD#example-mac"
```

After the first generation, write the Connect environment by hand (or let the
wizard do it): `~/.config/op/connect.env`, mode 600, containing
`OP_CONNECT_HOST=<url>` and `OP_CONNECT_TOKEN=<token>`. Replace the bootstrap
Git/SSH placeholders in `local.nix`, run the network-share bootstrap below when
configured, remove the install-only marker from the setup environment, and run
the routine switch in the operations guide to apply the final identity. This distinction follows the
[official nix-darwin installation instructions](https://github.com/nix-darwin/nix-darwin#step-2-installing-nix-darwin).

### Git

1. Ensure the signing key's public half is registered on GitHub for both
   authentication and signing.
2. After activation, inspect the generated Git settings:

   ```sh
   git config --global --get-regexp '^(user|gpg|commit|tag)\.'
   ```

3. Create a local signed test commit before publishing anything.

### Connect access

Nothing uses the 1Password desktop application, its SSH agent, the `op` CLI, or
a service account. Every read goes through the Connect server, and its token's
vault scope decides what this Mac can reach. Give the Connect token read access
to every vault this configuration reads: the vault holding the Git signing key,
the vault holding the AWS profiles, and the homelab vault (network-share
password and the `local.nix` Document). A vault outside the token's scope fails
loudly with an HTTP error from Connect; there is no fallback.

### Network shares

`modules/home/network-shares.nix` mounts the declared SMB shares at login and
reconciles them on a timer. The password is never in this repository or in
`local.nix`; it lives in the login Keychain.

On a machine with no Keychain entry yet, the human setup wizard invokes
`nix-config-bootstrap-network-share-password` with the declared server,
account and `local.networkShares.passwordReference`; it reads the password
through Connect. Routine activation only verifies the existing Keychain entry
and fails loudly if a configured entry is missing. Leave `passwordReference`
null to manage the Keychain entry through Finder instead.

Commit and tag signing are mandatory and go through the declarative signer. It
fetches the key named by `git.signingKeyReference` (vault and item IDs, ending
in `/private key?ssh-format=openssh`) from Connect, checks it against
`git.signingKey`, signs through OpenSSH with no agent, and removes its private
temporary key file afterward. Verification uses OpenSSH without credentials.

### Manual checklist

- Complete the [Karabiner first run](../../modules/home/karabiner.md#first-run),
  then run `scripts/check-karabiner.sh` and confirm every line reports `ok`.
  Grant Accessibility to **Karabiner-Core-Service**, not to
  `Karabiner-Elements.app` — see the linked section for why that distinction
  matters.
- Complete the [LinearMouse first run](../../modules/home/mouse.md).

These are protected macOS or application controls and cannot safely be approved
by Nix. TCC grants are per-machine and never survive a fresh install; there is
no supported way to script them without enrolling the Mac in an MDM, so expect
to grant each one exactly once.

Do not diagnose a keyboard problem by reading logs — run
`scripts/check-karabiner.sh`. It distinguishes a missing permission from an
unwritable configuration directory, which produce identical symptoms.
