# 1Password secret interface

This public repository contains no secret values.

Nix expressions and generated files can be copied into the Nix store. Never put
tokens, passwords, SSH private keys, recovery codes, private prompts or
decrypted secret text in this directory or any Nix option.

## Connect only

Every 1Password read on this Mac goes through the self-hosted 1Password Connect
server, and nothing falls back to anything else: no `op` CLI, no service
account, no 1Password SDK, no desktop-application integration, no biometric
prompt. A Connect failure stops with its reason.

The Connect host and token live in one 0600 env file
(`~/.config/op/connect.env`, `nixConfig.secrets.onePassword.connect.envPath`),
written once by the human setup (`scripts/setup-mac.sh connect`). It is never
exported to shells: each consumer reads it at its own seam, through the one
REST client in `scripts/onepassword_connect.py`:

- Git signing and GitHub transport — `scripts/git-connect-sign.py`, wired as
  `gpg.ssh.program` and `core.sshCommand`. It fetches the signing key, checks it
  against the declared public key, and runs OpenSSH with no SSH agent.
- AWS `credential_process` — `scripts/aws-credential-connect.py`, per call; no
  `~/.aws/credentials` is ever written.
- The network-share mount password and the `local.nix` backup note
  (`scripts/onepassword-connect-read.py`, `scripts/onepassword-connect-note.py`).

The service account, the `op run` launcher for `claude` and the 1Password SSH
agent were removed on 2026-10-07; all three had been switched off since the
move to Connect.

### Replacing the token

A Connect token's vaults are fixed when it is issued, so giving this Mac a new
vault means a new token. `nix-config-connect-rotate --add-vault VAULT` does the
whole replacement (`--dry-run` shows the plan first):

1. grants the Connect server (`local.nix` `onePassword.connectServer`) the vault;
2. issues a token for the current vaults plus the new ones, by vault ID, into a
   private file;
3. checks through Connect that it sees exactly those vaults;
4. installs it (`nix-config-connect-set-token`) and updates the stored copy
   (`nix-config-connect-store-token store`).

Steps 1–2 are the only `op` use on this Mac (Connect administration, with the
owner's 1Password approval). The previous token is never deleted
automatically: clusters or other machines may still use it. The command prints
the `op connect token delete` to run once nothing does.

## Local metadata

Git identity and the signing key's public half belong in ignored `local.nix`,
with an `op://` reference naming the item whose private key Connect returns:

```nix
git = {
  name = "Your public commit name";
  email = "an-email-verified-by-your-git-host@example.com";
  signingKey = "ssh-ed25519 YOUR_PUBLIC_KEY";
  signingKeyReference = "op://ExampleVault/aaaaaaaaaaaaaaaaaaaaaaaaaa/private key?ssh-format=openssh";
};
```

Neither the public key nor the author email is a secret: the email is embedded
in every commit and appears in the evaluated local Nix store. A GitHub privacy
address has the form `ACCOUNT_ID+USERNAME@users.noreply.github.com`. Never place
an SSH private key in this repository, `local.nix`, or any Nix expression.
