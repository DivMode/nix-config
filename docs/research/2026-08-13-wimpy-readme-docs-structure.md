# Wimpy-style README and documentation structure

Research date: 2026-08-13
Upstream revision inspected: [`9319a38`](https://github.com/wimpysworld/nix-config/tree/9319a38dcedab8793d4c2ae395a9c3207ebbd492)

## Conclusion

Wimpy does **not** use a short README backed by a conventional top-level
`docs/` manual. His current root README is 465 lines and contains the public
front door, architectural idea, repository structure, installation, everyday
apply commands, fallback commands, and a post-install checklist. Detailed
subsystem reference material is then stored beside the subsystem that owns it.

The useful pattern to copy is therefore **progressive disclosure and
co-location**, not the upstream README's exact length:

1. Keep orientation and the shortest successful setup/apply path in the root
   README.
2. Link from that path to detailed guides.
3. Keep implementation-specific behavior, caveats, and option references next
   to the owning module.
4. Keep cross-cutting architectural boundaries in `docs/`.

Our README is 428 lines, so raw length is not the meaningful difference. It
currently mixes front-door instructions with detailed keyboard mappings,
package-ownership policy, mouse migration history, AI rendering internals, and
1Password runtime design. Those are distinct reference topics and should not
all interrupt the new-host path.

## What Wimpy keeps in the root README

The upstream README contains:

- a one-paragraph statement of purpose and its distinguishing architecture;
- the managed-host inventory;
- a concise explanation of the broadcast-and-gate module model;
- a repository tree and directory-purpose table;
- brief shell and desktop summaries;
- the installation path, applying changes, and commands that work without the
  convenience wrapper;
- a manual post-install checklist.

These sections can be inspected directly in the current
[`README.md`](https://github.com/wimpysworld/nix-config/blob/9319a38dcedab8793d4c2ae395a9c3207ebbd492/README.md#how-it-works-), including
[`Structure`](https://github.com/wimpysworld/nix-config/blob/9319a38dcedab8793d4c2ae395a9c3207ebbd492/README.md#structure-),
[`Installing`](https://github.com/wimpysworld/nix-config/blob/9319a38dcedab8793d4c2ae395a9c3207ebbd492/README.md#installing-),
[`Applying Changes`](https://github.com/wimpysworld/nix-config/blob/9319a38dcedab8793d4c2ae395a9c3207ebbd492/README.md#applying-changes-), and
[`Post-install Checklist`](https://github.com/wimpysworld/nix-config/blob/9319a38dcedab8793d4c2ae395a9c3207ebbd492/README.md#post-install-checklist).

The root README gives the primary install sequence, then explicitly links to
the owning install module for the full reference rather than embedding every
edge case. See the link to
[`nixos/_mixins/scripts/install-system/README.md`](https://github.com/wimpysworld/nix-config/blob/9319a38dcedab8793d4c2ae395a9c3207ebbd492/nixos/_mixins/scripts/install-system/README.md)
from the root installation section.

## What Wimpy moves out of the root README

Detailed documentation lives beside its implementation:

- The root gives a short architectural explanation, while the complete typed
  option reference, data flow, helper API, usage patterns, and design decisions
  live in
  [`lib/noughty/README.md`](https://github.com/wimpysworld/nix-config/blob/9319a38dcedab8793d4c2ae395a9c3207ebbd492/lib/noughty/README.md).
- The root gives the install path, while prerequisites, token injection,
  destructive disk behavior, idempotency, and recovery details live in the
  [`install-system` module README](https://github.com/wimpysworld/nix-config/blob/9319a38dcedab8793d4c2ae395a9c3207ebbd492/nixos/_mixins/scripts/install-system/README.md).
- Codex runtime layout, mutable-state behavior, MCP configuration, skills, and
  hooks live beside the Codex module in
  [`home-manager/_mixins/agentic/codex/README.md`](https://github.com/wimpysworld/nix-config/blob/9319a38dcedab8793d4c2ae395a9c3207ebbd492/home-manager/_mixins/agentic/codex/README.md).
- User-specific GPG key behavior and activation caveats live beside that user
  module in
  [`home-manager/_mixins/users/martin/README.md`](https://github.com/wimpysworld/nix-config/blob/9319a38dcedab8793d4c2ae395a9c3207ebbd492/home-manager/_mixins/users/martin/README.md).

The upstream tree has many other feature-local README files under its NixOS and
Home Manager mixins. It does not currently have a general root `docs/`
directory. That is strong evidence that Wimpy's organizing rule is ownership:
documentation that explains one module lives with that module.

## Recommended boundary for this repository

### Keep in `README.md`

- Project purpose, supported platforms, and current status.
- A short stack/ownership summary: nix-darwin, Home Manager, Homebrew, and
  1Password.
- Repository layout.
- A **Quick start** that covers clone, create ignored `local.nix`, validate,
  activate, and complete manual approvals. Each step should link to the full
  setup guide.
- The three everyday operations: check, build without activation, and switch.
- A compact manual post-install checklist.
- A documentation index.
- A short statement of the rebuild boundary and a link to the full state
  boundary document.
- Later milestones, or a link to a roadmap if that list grows.

### Move to focused documentation

| Current README material | Destination | Reason |
| --- | --- | --- |
| Full local-variable explanations, first-activation details, and signing verification | `docs/setup/new-mac.md` | This is a procedural setup guide used occasionally. |
| Lock updates, evaluation variants, non-activating builds, and activation safety | `docs/operations/rebuild.md` | These are operational procedures, not orientation. |
| Homebrew cleanup policy, formula/cask ownership, Dock ownership, and macOS defaults | `modules/darwin/README.md` | These details are owned by the Darwin module family. |
| Exact Caps Lock/Return/Shift mappings, Logitech rationale, Raycast conflict, and permissions | `modules/home/karabiner.md` | Feature-local behavior and troubleshooting belong with `karabiner.nix`. |
| Zsh design, history state, Starship/font decisions, and framework exclusions | `modules/home/terminal.md` | Feature-local reference belongs with `terminal.nix`. |
| Runtime-manager ownership for mise, uv, and rustup | `modules/home/development.md` | Feature-local reference belongs with `development.nix`. |
| LinearMouse migration history and configuration ownership | `modules/home/mouse.md` | Mouse behavior belongs beside its owning module. |
| AI renderer outputs, mutable-file behavior, and future adapters | `ai/README.md` | This describes the AI source tree and its renderer. |
| 1Password app/CLI/agent/runtime distinctions and secret-flow details | Consolidate in `secrets/README.md` | A secrets interface document already exists and should be canonical. |
| Rebuildable-versus-mutable state | Keep in `docs/state-boundary.md` | This is cross-cutting architecture and already has the right home. |
| Composition and ownership model | Keep in `docs/architecture.md` | This is cross-cutting architecture and already has the right home. |

The `modules/home/*.md` names avoid moving implementation files immediately.
If those modules later become directories, move each pair to the exact
Wimpy-style shape—for example `modules/home/karabiner/default.nix` and
`modules/home/karabiner/README.md`—without changing the document's purpose.

## Proposed root README outline

```text
# nix-config
Purpose + status

## What it manages
Short ownership summary

## Repository layout
Tree + documentation links

## Quick start
Minimal new-Mac path with links to docs/setup/new-mac.md

## Apply changes
Check / build / switch commands

## Post-install checklist
Only unavoidable interactive approvals and sign-ins

## State boundary
Two sentences + link to docs/state-boundary.md

## Documentation
Setup, operations, Darwin, Home Manager, AI, and secrets index

## Later milestones
Short list or roadmap link
```

This follows Wimpy's actual information architecture: the README remains a
useful operational front door, while detailed reference and caveats live with
their owning subsystem. It also avoids copying personal host inventories or
other identity-specific material from the upstream repository.
