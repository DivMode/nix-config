# macOS developer toolchain recommendation

Date: 2026-08-12

## Decision

Use a layered, single-owner model:

1. **nix-darwin declares macOS state and native/vendor Homebrew casks.**
2. **Home Manager installs Zsh, Git, manager executables, and portable workstation CLIs from Nix.**
3. **mise manages project-selected Node toolchains only.**
4. **uv manages Python interpreters, environments, dependencies, tools, and lockfiles.**
5. **rustup manages Rust toolchains, components, targets, and project overrides.**
6. **Each source repository owns its runtime versions and project dependencies.**

Install `mise`, `uv`, and `rustup` from the flake-declared nixpkgs input through Home Manager. The input becomes pinned when `flake.lock` is generated. Do not install a second global `node`, `python`, or `rust` package alongside them. Let project files select runtime versions, and keep npm/Python/Rust libraries in each project's lockfiles. Use `gdalMinimal` for a compact GDAL command suite with VRT, WebP, SQLite/MBTiles, and projection support without unrelated cloud drivers.

This preserves the user's requirement that machine software is declared in code while avoiding competing owners for the same executable.

## Why mise instead of nvm, asdf, or Volta

| Manager | Strengths | Costs | Verdict |
| --- | --- | --- | --- |
| **mise** | One manager with automatic per-directory switching; supports `mise.toml`, `.tool-versions`, and idiomatic version files; can lock resolved versions | Adds shell activation and its own downloaded tool state | **Recommended for Node in this configuration** |
| **nvm** | Mature Node-only manager; widely understood `.nvmrc` format | Per-user shell function, not a normal executable; automatic directory switching requires extra shell hooks; upstream explicitly says Homebrew installation is unsupported | Do not install for a new declarative setup |
| **asdf** | Polyglot and established `.tool-versions` ecosystem | Runtime plugins and plugin dependencies add more setup; mise already reads `.tool-versions` and can use legacy asdf plugins | Use only for an existing asdf-standardized team |
| **Volta** | Excellent Node-only shims; pins Node and package tools in `package.json` | Does not solve Python, Rust, or general CLI versions | Best Node-only alternative, not the best fit here |

mise installs missing versions and places the selected tool ahead of system paths when a matching project configuration is active. Its native Node backend can verify Node's signatures; it can also read Node idiomatic version files when configured. Sources: [mise dev tools](https://mise.jdx.dev/dev-tools/), [mise Node support](https://mise.jdx.dev/lang/node.html), [mise/asdf comparison](https://mise.jdx.dev/dev-tools/comparison-to-asdf.html), [nvm upstream README](https://github.com/nvm-sh/nvm/blob/master/README.md), [asdf setup](https://asdf-vm.com/guide/getting-started.html), [Volta design](https://docs.volta.sh/guide/understanding).

### Node policy

- Home Manager/Nix owns only the `mise` executable, not Node.
- Each project checks in an exact or intentionally bounded Node selection, preferably in `mise.toml`. A `.node-version`, `.nvmrc`, or `package.json` `engines` constraint may be retained for ecosystem compatibility, but one file should be canonical.
- Check in `mise.lock` when exact resolution across machines matters; avoid `latest` in committed production projects.
- npm package dependencies remain in `package.json` plus `package-lock.json`; use `npm ci` for the locked install. Do not globally install Wrangler, TypeScript, Astro, Vitest, or Playwright through Homebrew.

The machine-wide Node 24 selection is only a fallback. Each project should commit its own exact Node selection rather than hiding that requirement in the Mac configuration.

## Python: uv should own the Python development workflow

uv can download Python versions, select them using `.python-version` and `requires-python`, create environments, resolve dependencies, and produce a cross-platform `uv.lock`. It also provides isolated Python CLI installation through `uv tool`. Sources: [uv overview](https://docs.astral.sh/uv/), [Python version management](https://docs.astral.sh/uv/concepts/python-versions/), [uv projects](https://docs.astral.sh/uv/guides/projects/), [uv tools](https://docs.astral.sh/uv/concepts/tools/).

Recommended ownership:

- Home Manager installs `uv` from nixpkgs.
- uv installs Python interpreters and owns Python project environments.
- Python projects check in `pyproject.toml`, `uv.lock`, and, when a single interpreter default is useful, `.python-version`.
- Do not let mise and uv independently install Python. Keep Python out of the mise tool list.

Installing uv does not automatically convert existing `pip` workflows. Migrate each project deliberately to a uv project and lockfile before removing a Python path that the project still uses.

uv-managed CPython builds are based on Astral's `python-build-standalone`, because Python does not publish portable CPython binaries. Native extension builds can still require Apple's compiler and SDK tools.

## Rust: Nix-provided rustup is the sole selector

`rustup` is Rust's toolchain authority: it installs channels, targets, and components and honors `rust-toolchain.toml`. Although mise has a Rust backend, enabling two selectors would obscure ownership, so Rust is deliberately absent from mise here. Sources: [rustup toolchains](https://rust-lang.github.io/rustup/concepts/toolchains.html) and [rustup overrides](https://rust-lang.github.io/rustup/overrides.html).

Recommended ownership:

- Home Manager installs nixpkgs `rustup`, whose package includes the standard proxy commands.
- rustup selects Rust per project using the standard `~/.rustup` and `~/.cargo` homes; do not configure isolated homes.
- Rust projects check in `rust-toolchain.toml` when they require a specific channel, components, or targets; `Cargo.lock` owns crate resolution.
- Do not also install Nixpkgs or Homebrew `rust`, or add Rust to mise.

Rust is provided as a general workstation capability; individual projects must declare their own toolchain requirements.

## Baseline Nix tools

### Declare now

| Formula | Evidence in the repository |
| --- | --- |
| `git` | Source-control workflows |
| `gh` | GitHub pull-request and repository workflows |
| `jq` | Structured-data processing in shell workflows |
| `ripgrep` | Baseline development/search utility already selected in the Mac config |
| `fd` | Useful paired file search; not a runtime dependency, but reasonable baseline developer ergonomics |
| `just` | Repeatable project task execution |
| `mise` | Node version selection |
| `uv` | Intended Python interpreter/environment/dependency manager |
| `rustup` | Official Rust toolchain/components/targets authority |
| `kubectl` | Kubernetes administration |
| `pulumi` | Infrastructure-as-code workflows |
| `crane` | Container registry inspection and transfer |
| `gdal` | Geospatial data conversion and inspection |
| `pmtiles` | PMTiles archive inspection and packaging |

The Homebrew `1password-cli` cask supplies `op`, which the `justfile` uses for runtime secret retrieval. It is a documented vendor-integration exception rather than a portable formula.

### Do not install globally

- TypeScript, test runners, web frameworks, and other JavaScript project tools: projects should pin these in their own manifests and lockfiles.
- `tippecanoe`: add it only when local vector-tile generation is an explicit workstation requirement.
- Cluster-specific administration tools: add them only when a concrete operator workflow requires them.
- Docker Desktop or another container GUI: choose a local container runtime separately if local container builds become a requirement.

## Xcode and Command Line Tools

Apple offers Command Line Tools for Xcode as the smaller package for UNIX-style and native compilation. Full Xcode already includes the command-line tools. Apple notes that some commands, including `xcodebuild` and `xctrace`, are full-Xcode-only. Source: [Apple: Installing the command-line tools](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools).

### Decision now

Keep **Command Line Tools**, not full Xcode. This Mac already has CLT selected at `/Library/Developer/CommandLineTools`, and `/Applications/Xcode.app` is absent. Node native modules, Python native extensions, Rust crates with C dependencies, and Homebrew builds need the compiler/SDK layer. Install full Xcode only when an Apple-platform project requires it.

On a new Mac, the initial supported installation is `xcode-select --install`; it displays an Apple agreement/install dialog. macOS can update CLT through Software Update. This is a bootstrap exception: nix-darwin/Homebrew cannot silently bypass Apple's license/trust interaction.

### When full Xcode is needed

Install it only for iOS/macOS/watchOS/visionOS development, simulator/device runtimes, signing workflows, or a full-Xcode-only tool. Then choose one path:

- **Ordinary single current Xcode:** declare `mas` and the Xcode App Store ID through nix-darwin. The user must already be signed into the App Store, and installation may require administrator authorization. `mas` automates App Store acquisition; it is not a true Xcode version manager. Source: [mas upstream repository](https://github.com/mas-cli/mas).
- **Pinned, multiple, beta, or older Xcodes:** declare the `xcodes` formula through Homebrew, check an `.xcode-version` into the Apple project, and use xcodes to install/select it. xcodes supports version selection and Apple authentication, with credentials stored in Keychain. Source: [xcodes upstream repository](https://github.com/XcodesOrg/xcodes), [Homebrew xcodes formula](https://formulae.brew.sh/formula/xcodes).

Neither option makes Apple authentication, license acceptance, signing certificates, or trust prompts disappear. Those are intentional first-boot/manual boundaries.

## Relationship to Wimpy's repository

Wimpy's `nix-config` at commit `97efaed821fcbae491b33231ec62753c127b44c3` was inspected as a structural reference, not treated as product documentation.

Relevant patterns:

- nix-darwin enables `nix-homebrew` and declares Homebrew casks.
- common packages are declared through Nix, while workstation language modules add `nodejs`, `python3`, and `uv` from Nixpkgs.
- validation uses formatting, flake evaluation/checks, and non-activating builds rather than a hand-maintained test duplicating the package list.

Our selected boundary now follows the reusable pattern: Nix/Home Manager own portable tools and Homebrew owns native/vendor casks. The exact package set remains specific to this machine.

## Reproducibility and bootstrap boundaries

Declarative does not mean every byte belongs in the Nix repository:

- `flake.lock` pins the machine configuration inputs.
- nix-darwin declares Homebrew cask names. The current formula list is empty. With immutable taps, the flake input revisions control cask definitions, but downloaded applications can still have vendor behavior and signatures outside the Nix store.
- Project runtime files (`mise.toml`/`mise.lock`, `.python-version`, `pyproject.toml`/`uv.lock`, `rust-toolchain.toml`, language dependency lockfiles) pin developer environments.
- User data and credentials remain state: App Store sign-in, 1Password sign-in/integration approval, GitHub authentication, Apple licenses, Keychain entries, SSH trust, signing identities, and mise trust for repository configuration cannot safely be faked or embedded in a public repository.
- On first boot, install/accept CLT, activate the declared nix-darwin generation, sign into required services, trust audited project configuration, and run the declared runtime installers. Automate those steps only where upstream provides a non-interactive, auditable interface.

## Implementation sequence

1. Add the baseline portable packages above to Home Manager; retain the strict non-zapping Homebrew cleanup policy for native/vendor casks.
2. Use the Nix Zsh package consistently in nix-darwin and Home Manager, and initialize Nix-provided mise there.
3. Add a checked-in user-level mise fallback only if a global default is desired; keep exact production runtime pins in each project.
4. Add project-local `mise.toml` and lock decisions where exact Node versions matter.
5. Migrate existing Python workflows to uv before removing a Python/pip path they still use.
6. Install and accept Apple CLT once; do not add full Xcode until an Apple-platform requirement exists.
7. Validate the Nix configuration using format, flake evaluation/check, and a non-activating build. Do not create a custom assertion that duplicates the package list.

## Terminal and multiplexer decision

Install cmux as a Homebrew cask because it is a native macOS terminal application. Install Herdr from its official release flake, declared at the `github:ogulcancelik/herdr/v0.8.0` release and locked by `flake.lock`, through Home Manager. Herdr's flake exports a default package for `aarch64-darwin` and `x86_64-darwin`; its nixpkgs input follows this repository's locked nixpkgs to avoid a second package graph.

cmux and Herdr are complementary. cmux renders the native terminal window. Herdr is a persistent, tmux-style terminal workspace manager that runs inside an existing terminal, keeps panes and agent processes alive, and reattaches with the `herdr` command. Herdr is not a second `.app`.

Anthropic's Homebrew `claude-code` cask installs the terminal-based `claude` command. The separate Homebrew `claude` cask is the desktop application and is intentionally not declared.
