# 1Password secret interface

This public repository contains no secret values.

Nix expressions and generated files can be copied into the Nix store. Never put
tokens, passwords, SSH private keys, recovery codes, private prompts, decrypted
secret text, or a 1Password service-account token in this directory or any Nix
option.

The Home Manager module accepts two public-safe declarations:

```nix
nixConfig.secrets.onePassword = {
  references = {
    exampleApiToken = "op://Automation/Example API/credential";
  };

  environment = {
    EXAMPLE_API_TOKEN = "exampleApiToken";
  };
};
```

Every reference must start with `op://` and contain a vault, item, and field.
Every environment mapping must point to a declared reference name. A literal
secret value fails module evaluation rather than being accepted into generated
state. The generic values above are examples, not working account identifiers.

The basic Mac profile declares both the 1Password desktop application and its
separate CLI package, but leaves runtime injection disabled. If runtime injection
is deliberately enabled later, the generated `ai.env` contains only
`NAME=op://...` references, and the `claude` launcher resolves them with `op run`
at process start. There is no Codex launcher. The wrapper targets the absolute,
architecture-correct Homebrew Claude Code terminal binary rather than a Nix AI
package. Never replace this with `builtins.readFile` on a
decrypted file, `op read` during evaluation, or a derivation that writes resolved
values: all of those can expose secrets through the Nix store or build logs.

After the first rebuild, sign in to the 1Password desktop application manually.
The setup wizard also requires **Settings > Developer > Integrate with 1Password
CLI** while it discovers public SSH metadata after the first switch. The dormant
runtime-injection feature uses the same integration if enabled later. Nix cannot
perform the protected sign-in or toggle that GUI setting.

The macOS 1Password application owns:

- account authentication and biometric unlock;
- all actual secret values.

SSH-agent integration is independent from runtime API-secret injection. Set
`nixConfig.secrets.onePassword.sshAgent.enable = true;` when desired. With it
enabled, the application owns its agent socket and `~/.ssh/1Password/config`;
Home Manager owns only the include and socket reference and never overwrites the
application-generated file.

The ignored local input also declares an ordered list of SSH Key item IDs:

```nix
onePassword.sshAgentKeyIds = [ "aaaaaaaaaaaaaaaaaaaaaaaaaa" ];
```

Home Manager renders those IDs to 1Password's documented
`~/.config/1Password/ssh/agent.toml`. This makes keys from non-default vaults
available without publishing item or vault names. Item IDs are local metadata,
not secret values; private keys remain exclusively in 1Password.

Git identity and the selected SSH public key belong in ignored `local.nix`.
Neither the public key nor the author email is a secret. The email is embedded
in commits and appears in the evaluated local Nix store. Never place an SSH
private key in this repository, `local.nix`, or any Nix expression. Git signing
uses 1Password's `op-ssh-sign`, keeping the private key inside 1Password.

The Git identity shape is:

```nix
git = {
  name = "Your public commit name";
  email = "an-email-verified-by-your-git-host@example.com";
  signingKey = "ssh-ed25519 YOUR_PUBLIC_KEY";
};
```

A GitHub privacy address has the form
`ACCOUNT_ID+USERNAME@users.noreply.github.com`; the numeric prefix is the GitHub
account ID. Either a verified normal address or a privacy address works, but the
chosen address is always public in commit metadata.

Shell wrappers inject runtime values only into the child process they launch.
They do not configure applications opened from Finder, Dock, or Spotlight. Do
not copy resolved values into `launchctl`, Nix settings, or persistent files as
a workaround.
