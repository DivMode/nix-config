# New Mac setup

This documents bootstrap and its current limitations. The public repository
contains no personal or machine identity.

## One command

1. In Setup Assistant, create the macOS account with the same short name as
   the Mac it replaces (the stored `local.nix` names it). Any computer name is fine; the configuration never sets or uses it.
2. Plug in the external `Data` drive and join the network the 1Password Connect
   server is on.
3. In Terminal:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/DivMode/nix-config/main/scripts/bootstrap.sh | bash
   ```

4. When asked, paste the Connect URL (`onePassword.connectHost`, in the old
   Mac's `local.nix` and in the 1Password Secure Note `nix-config local.nix`) and the Connect token (the `access-token` field of the
   Connect server's credentials item in 1Password; copy it on a phone or the
   web, then Cmd-V on the Mac via Universal Clipboard; the desktop application
   is not needed). Type your Mac password once when asked.
5. Grant the macOS permissions listed in the manual checklist below.

`scripts/bootstrap.sh` installs Apple's Command Line Tools and Nix without
prompts, clones or updates this repository at `/Volumes/Data/Developer/nix-config`,
and runs `scripts/setup-mac.sh`. The wizard writes the Connect environment
(`~/.config/op/connect.env`, mode 600; the token never reaches `.setup-mac.env`),
finds the Secure Note `nix-config local.nix` through Connect, checks that its account, home and architecture match this Mac, installs
everything declared, seeds the network-share password from Connect, and runs
`scripts/rebuild.sh`. The computer's name is not part of the configuration: macOS owns it. Nothing uses the 1Password desktop application, the
`op` CLI or a service account, and any failure stops with the reason.

## Manual fallback

For a brand-new host with no stored `local.nix` (the wizard stops with an
error in that case), write a **complete** `local.nix` first: copy
`local.example.nix` and fill every field with real values, including the Git
signing key's public key and its `git.signingKeyReference` (the placeholders
below are rejected). Place it in the clone and run the one command again; the
wizard keeps a complete `local.nix` that matches this Mac.

### Create the local host input

Copy the public template:

```sh
cp local.example.nix local.nix
```

For the first pass, fill only these Mac fields:

- `user`: short macOS account name;
- `system`: `aarch64-darwin` for Apple Silicon or `x86_64-darwin` for Intel;
- `homeDirectory`: absolute `/Users/<account>` path;

Leave the public Git and 1Password placeholders intact for the first switch.
They are structurally valid bootstrap values, not credentials and not a usable
signing identity.

After the first switch, replace them (copy the values from the old Mac's
`local.nix`, or from 1Password on the web or a phone):

- `git.name`: public author name embedded in commits;
- `git.email`: Git-host-verified address embedded in commits;
- `git.signingKey`: Ed25519 SSH **public** key used for signing;
- `git.signingKeyReference`: reference to that same item's private key, ending
  in `/private key?ssh-format=openssh`, readable by the Connect token;
- `onePassword.sshAgentKeyIds`: still a required, non-empty list of SSH Key
  item IDs (the Git signing key first). The 1Password SSH agent is disabled, so
  nothing offers these keys; the list only satisfies evaluation.

The email is not secret: Git embeds it in every commit and local Nix evaluation
places it in the Nix store. Use a GitHub privacy address if public commits must
not expose a personal mailbox. Its numeric prefix is the GitHub account ID, not
a key identifier.

Copy only the public key from the existing SSH Key item. Never put an SSH
private key, password, token, recovery value, or private repository detail in
`local.nix` or another Nix expression. Item IDs keep private item and vault
names out of the public repository.

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
metadata, never the token or private key. Every rebuild saves it to the
1Password Secure Note automatically.

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
to the vault holding the Git signing key and the vault holding the AWS profiles,
and **read and write** access to the homelab vault: it holds the network-share
password and the `local.nix` Secure Note that every rebuild creates or updates. A vault outside the token's scope fails
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
