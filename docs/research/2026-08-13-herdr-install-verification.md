# Herdr installation verification

Verified 2026-08-13 against Herdr's official repository, release source, and the
active Home Manager profile on this Mac.

## Conclusion

The configuration declares and has installed the correct project: **Herdr
0.8.0**, the terminal workspace manager for AI coding agents maintained at
[`herdrdev/herdr`](https://github.com/herdrdev/herdr). The older input spelling
`ogulcancelik/herdr` is not a different project: GitHub redirects it to the
official organization repository, and the lock file pins the official `v0.8.0`
release commit. The release page is
[`herdrdev/herdr v0.8.0`](https://github.com/herdrdev/herdr/releases/tag/v0.8.0).

Herdr is deliberately **not a macOS `.app`** and therefore does not appear in
Applications, Launchpad, or the Dock. Its official README describes it as one
Rust binary that runs inside an existing terminal, and says to start it with
`herdr`: [official README at v0.8.0](https://github.com/herdrdev/herdr/blob/v0.8.0/README.md).
cmux is the native terminal application; Herdr runs inside cmux.

## Nix verification

Herdr does have an official Nix flake. Its install documentation supports `nix
run`, `nix build`, and `nix profile install`, and recommends pinning a release
tag: [official Nix installation instructions](https://github.com/herdrdev/herdr/blob/v0.8.0/docs/next/website/src/content/docs/install.mdx#install-with-nix).

The upstream [`flake.nix`](https://github.com/herdrdev/herdr/blob/v0.8.0/flake.nix)
exports both `packages.aarch64-darwin.herdr` and
`packages.aarch64-darwin.default`; `default` is the same `herdr` derivation. It
also exports a default app whose program is `.../bin/herdr`. The upstream Nix
package identifies `herdr` as its main program and supports Darwin:
[`nix/package.nix`](https://github.com/herdrdev/herdr/blob/v0.8.0/nix/package.nix).

This repository uses the correct output:

- [`flake.nix`](../../flake.nix) declares
  `github:ogulcancelik/herdr/v0.8.0`; GitHub resolves that to the official
  `herdrdev/herdr` repository.
- [`flake.lock`](../../flake.lock) pins release
  commit `346411fa21afd297f5ed3b3fa56f9e3fbf7654b7`.
- [`modules/home/development.nix`](../../modules/home/development.nix)
  installs `inputs.herdr.packages.${pkgs.stdenv.hostPlatform.system}.default`,
  which is exactly upstream's architecture-specific default package.

Live verification on this Apple-silicon Mac found:

- `herdr --version` reports `herdr 0.8.0`.
- The declared user's active Home Manager profile contains `bin/herdr`, which
  resolves to the Nix store package `herdr-0.8.0`.
- The executable is a native arm64 Mach-O binary.
- The package contains no `.app` bundle.

Therefore the app was not omitted and a similarly named package was not
installed. Open cmux (or Terminal), then run `herdr`.

## Herdr runtime configuration

Herdr also has its own runtime configuration, separate from its Nix packaging.
The official path on macOS is `~/.config/herdr/config.toml`; the complete
defaults can be printed with `herdr --default-config`:
[official configuration documentation](https://github.com/herdrdev/herdr/blob/v0.8.0/docs/next/website/src/content/docs/configuration.mdx).

No Herdr config directory currently exists on this Mac. That is valid because
Herdr works without a config file, but it means Herdr's runtime preferences are
not yet declaratively managed by Home Manager. This report does not create that
file or launch Herdr.
