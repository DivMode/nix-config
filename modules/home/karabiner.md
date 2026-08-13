# Karabiner keyboard configuration

Karabiner-Elements is installed as a native Homebrew cask. Home Manager owns the
complete `~/.config/karabiner` directory and generates `karabiner.json` from
`karabiner.nix`. The whole-directory link is required for reliable reloads.

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

Grant the background-service, Accessibility, and Driver Extension permissions
requested by Karabiner. Set Raycast's native Hyper Key to **None** and verify it
after Cloud Sync; Raycast exposes no supported declarative control for that
setting. Do not add mouse rules—LinearMouse exclusively owns mouse behavior.
