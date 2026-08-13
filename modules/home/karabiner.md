# Karabiner keyboard configuration

Karabiner-Elements is installed as a native Homebrew cask. Home Manager generates
`karabiner.json` from `karabiner.nix` and installs it into `~/.config/karabiner`
as a **real, writable file** — never a symlink.

That is not a style choice. Karabiner rewrites `karabiner.json` at runtime for
the selected profile and any GUI edit, and it permission-checks the directory
before loading. Pointing `~/.config/karabiner` at the read-only Nix store makes
it log `permissions failed: Operation not permitted` and silently never apply a
single rule. Home Manager cannot express a writable copy (`home.file` always
symlinks; nix-community/home-manager#3090 is still open), so `karabiner.nix`
reasserts the declared content from an activation script instead. Nix owns the
desired state; Karabiner owns runtime drift between activations.

Run `scripts/check-karabiner.sh` to verify the whole chain at once.

## Mappings

- Hold Caps Lock: Hyper (Control + Option + Command + Shift).
- Tap Caps Lock: Escape.
- Hyper + I/J/K/L: Up/Left/Down/Right.
- Tap Return normally; hold Return for Control.
- Physical Escape: backtick/tilde.
- Left Shift + Right Shift together: real Caps Lock.

The last mapping means both distinct Shift keys simultaneously, not a double tap
of one key.

`fn_function_keys` remains empty so a Logitech keyboard retains its native top
row, Fn+Escape toggle, and device-switch behavior. The public profile declares
an ANSI virtual keyboard. Change the declarative layout for ISO or JIS rather
than editing the immutable Karabiner UI state.

## First run

Two permissions must be granted by hand. TCC state never survives a fresh
install and cannot be scripted: `tccutil` has no grant verb, the TCC database is
SIP-protected, and PPPC configuration profiles are rejected unless they come
from a user-approved MDM server. One click each, once per machine.

1. **Driver Extension** — System Settings > General > Login Items & Extensions >
   Driver Extensions.
2. **Accessibility** — grant it to **Karabiner-Core-Service**, at
   `/Library/Application Support/org.pqrs/Karabiner-Elements/Karabiner-Core-Service.app`.

   Granting it to `Karabiner-Elements.app` does nothing. That bundle is
   `org.pqrs.Karabiner-Elements.Settings` — only the settings window. The
   session agent that requests the permission and the daemon that grabs the
   keyboard both live in `Karabiner-Core-Service.app`. This distinction is the
   single easiest way to lose an afternoon here, because the list entry looks
   correct and `device_grabber` still never starts.

Karabiner 16 does **not** additionally need Input Monitoring; the official docs
state it is covered by Accessibility from 16.0.0 onward.

Then verify with `scripts/check-karabiner.sh` rather than guessing — it reports
which link in the chain is broken. Finally, set Raycast's native Hyper Key to
**None** and verify it after Cloud Sync; Raycast exposes no supported
declarative control for that setting. Do not add mouse rules—LinearMouse
exclusively owns mouse behavior.
