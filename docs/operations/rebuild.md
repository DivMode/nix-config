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
sudo env NIX_CONFIG_LOCAL="$NIX_CONFIG_LOCAL" \
  /run/current-system/sw/bin/darwin-rebuild switch --impure \
  --flake "path:$PWD#example-mac"
```

Activation is the only step above that changes the running Mac.

## Lock updates

`flake.lock` pins every declared input. Update it intentionally:

```sh
nix flake lock
```

Then repeat formatting, evaluation, checks, and the non-activating build. Do not
activate an unreviewed lock update.

## Safety boundaries

- Homebrew reconciles declared casks with cleanup set to `"uninstall"`, never
  global `"zap"`.
- Home Manager fails on unmanaged-file collisions instead of overwriting them.
- macOS privacy approvals, account sign-ins, and application sessions remain
  interactive state.
