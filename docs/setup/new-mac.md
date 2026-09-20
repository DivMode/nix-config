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

The wizard currently requires a complete, matching `local.nix` before its
first build. Its placeholder writer omits required fields, so an empty or
mismatched input fails evaluation before 1Password can be installed and before
a saved document can be restored. Use the full-template manual preparation
below first. This existing limitation is not fixed by the install-only mode.

With that complete input in place, run:

```sh
./scripts/setup-mac.sh
```

The wizard preserves the matching input, runs an install-only first switch
without credential maintenance, and pauses for 1Password sign-in. It can then
**restore the ignored `local.nix` from 1Password**: each host's canonical copy lives as
a Document item titled `nix-config local.nix <LocalHostName>`, validated
against the detected account/hostname/architecture before it is trusted. After a complete bootstrap input has allowed that first switch, the Connect
host, 1Password item IDs, and AWS profiles come back with the restore. The wizard explicitly bootstraps the cached service
account and network-share Keychain entry before the final, ordinary switch.
Personal-account access belongs to these interactive setup steps, not routine
activation. Stopping after the first switch leaves setup incomplete.

If no matching stored copy is available, the identity writer collects Git/SSH
metadata but still omits required configuration fields. That path cannot finish
unattended; complete and validate the input manually before proceeding. Private
keys never leave 1Password.

`scripts/rebuild.sh` keeps the stored copy current: after every successful
activation it compares `local.nix` against the Document item and re-uploads it
when they differ, then downloads the result to verify exact bytes. Routine
rebuilds require the configured service account and never fall back to personal
sign-in. The setup wizard creates the initial document; a failed routine read
does not automatically create a replacement.

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
  in `/private key?ssh-format=openssh`, readable by the service account;
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
metadata, never the token or private key. A successful routine rebuild updates
the stored backup with this field.

GitHub SSH fetches and pushes use the same service-account key through the
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

The first generation installs 1Password and its CLI. Open 1Password, sign in,
enable its SSH agent and CLI integration, then replace the bootstrap Git/SSH
placeholders and credential references in `local.nix`. In the human setup
terminal, run the generated `nix-config-bootstrap-onepassword` command with
the declared service-account reference, then the network-share bootstrap below
when configured. Remove the install-only marker from the setup environment,
and open a fresh terminal so the declared shell initialization loads the cached
service account. The initial recovery Document must exist before using the
routine rebuild. Run the routine switch in the operations guide to apply the
final identity. This distinction follows the
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

### The service account and its vaults

**Scope the service account to every vault this machine reads, at the moment you
create it.** 1Password states it plainly: "Service account permissions, vault
access, and Environment access are immutable." There is no control anywhere —
website, app, or CLI — to add a vault afterwards. Getting it wrong costs a new
account and a token swap on every machine.

This configuration currently reads two vaults:

- the **business vault**, for the AWS profiles and the Connect credentials
- the **homelab vault**, for the service-account token itself, the network share
  password, and the `local.nix` document backup that `scripts/rebuild.sh`
  uploads after every activation

The `local.nix` backup lives in the homelab vault deliberately. It is the
machine's own recovery material — `setup-mac.sh` restores it on a wiped Mac — so
it must not sit behind access that can be revoked independently of the machine,
such as a client or employer relationship ending. Losing that vault means losing
the ability to set up your own computer, and you would discover it at the worst
possible moment.

Grant `read_items` **and** `write_items` on both. Write is not optional on the
vault holding the `local.nix` backup: `rebuild.sh` reports failure when the upload
or verification fails. Activation may already have succeeded; the recovery copy
must be repaired before treating the maintenance run as complete.

`setup-mac.sh` offers the homelab vault as the default answer when it asks which
vault holds `local.nix`, so the usual case is a single Enter. That name can be
written into a tracked script only because `local.nix` lists it in
`publicTerms`; the private-name guard derives its denylist from
`onePassword.vault`, so without that entry a generic vault name is guarded as
though it were secret. A vault named after a company or a client must never be
added to `publicTerms`.

Leave `share_items` off. Nothing here shares items, and it is the one permission
that turns a leaked token into an exfiltration path needing no 1Password
credentials to redeem.

Allowing the account to create vaults is harmless: a service account can only
delete vaults it created, never a pre-existing one it was merely granted.

### Network shares

`modules/home/network-shares.nix` mounts the declared SMB shares at login and
reconciles them on a timer. The password is never in this repository or in
`local.nix`; it lives in the login Keychain.

On a machine with no Keychain entry yet, the human setup wizard invokes
`nix-config-bootstrap-network-share-password` with the declared server,
account and `local.networkShares.passwordReference`. For manual setup, run
that generated command with the same three arguments in the signed-in human
terminal. It can use the desktop integration in this explicit bootstrap step.
Routine activation only verifies the existing Keychain entry and fails if a
configured entry is missing; it never falls back to personal authentication.
Leave `passwordReference` null to manage the Keychain entry through Finder
instead.

The earlier 2026-08-21 end-to-end observation covered activation-time seeding.
It does not establish end-to-end verification of the separate bootstrap flow.

Home Manager requires SSH-format commit and tag signatures through the declared
service-account signer. Set `git.signingKeyReference` in ignored `local.nix` to
the approved key's private-key reference with `?ssh-format=openssh`; the existing
`git.signingKey` is its public identity. The service account must have read access
to that item. Its token must already be present in the process environment.
The signer rejects missing service-account authentication and conflicting
Connect variables rather than falling back to the desktop app. It checks the
retrieved key against the configured public key, signs through OpenSSH, and
removes its private temporary key file afterward. Verification uses OpenSSH
without accessing credentials. Commit and tag signing remain mandatory.

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
