# Official Nix installer shell-file handoff

## Why a fresh Mac can report unrecognized bashrc and zshrc

`bootstrap.sh` uses the current official multi-user Nix installer. That installer
changed from appending its `shell_source_lines()` hook to prepending it in
[NixOS/nix PR #14021](https://github.com/NixOS/nix/pull/14021), commit
`a408bc3e30e3e5b7ff61596d1072973679761363`.

Our nix-darwin pin, `c3e90c89649b07d1a96e4b9dd6cd0d6e44b91a74`, recognizes the
stock Apple files and the older appended-hook variants. The same standard
contents in the new order have different SHA-256 hashes, so its `checks` phase
rejects `/etc/bashrc` and `/etc/zshrc` before activation can replace them. This
reproduces the two-file error without any user customization. An individual
Mac's exact cause still needs its file hashes; the error alone cannot prove
what those files contain.

## Declarative fix

`modules/darwin/default.nix` extends `environment.etc.<file>.knownSha256Hashes`
with only the following audited stock-plus-prepended-hook variants:

| File | Variant | SHA-256 |
| --- | --- | --- |
| bashrc | Stock Apple bashrc plus official hook | `8b5e3466922d1ae34bc145e21c7e53e7329a7a7b58b148b436bd954d5e651ac3` |
| zshrc | Pre-macOS 26 stock plus official hook | `af60f7af4a5b4c1b0efe950e3e3f3ee8b136834ecb46fd7dba76f4b66adbc3e1` |
| zshrc | macOS 26 stock plus official hook | `cf0f7b7775b4c058d6085d9e7e57d58c307ca43730f8e4d921a9ef4e530e7e16` |

This extends, rather than replaces, nix-darwin's existing hash lists. No host
files are read during evaluation, no overwrite check is disabled, and no
pre-activation script moves arbitrary files out of the way. Home Manager's
home-directory collision policy is unchanged.

During normal activation, nix-darwin renames recognized originals to
`/etc/bashrc.before-nix-darwin` and `/etc/zshrc.before-nix-darwin`, then installs
its managed links. This change leaves upstream backup behavior unchanged;
retain any already-existing backups separately before a repeated takeover.
Already-managed links continue through nix-darwin's existing idempotent path.

## Resume setup

After updating the existing checkout to include this fix, run the wizard from
that checkout:

```sh
./scripts/setup-mac.sh
```

Use the wizard for incomplete first setup; `scripts/rebuild.sh` assumes the
first nix-darwin generation is already installed. The normal one-command
bootstrap updates only `main`, so a fix on an unmerged branch must be checked
out explicitly and run through `setup-mac.sh` directly.

Do not delete or blindly rename the two files. If the error remains, read their
hashes first:

```sh
shasum -a 256 /etc/bashrc /etc/zshrc
```

A different hash means different bytes: inspect those files locally before
adding a narrowly reviewed hash or moving important settings into the Nix
configuration. Do not add a hash obtained from a host without reviewing its
contents, and do not commit private shell contents or credentials.

## Regression check

```sh
python3 scripts/check-shell-bootstrap.py
```

The check uses public Apple source fixtures and the exact official installer
hook. It verifies stock and appended hashes against the pinned nix-darwin
values, verifies all three newly recognized prepended variants, and verifies
that added or changed shell commands are not recognized by this extension.
It never reads or mutates the host's `/etc` files and is also wired into
`nix flake check` as `shell-bootstrap-hashes` for all four configured platforms.
