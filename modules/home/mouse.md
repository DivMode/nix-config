# Mouse configuration

LinearMouse is the sole mouse-event owner. Homebrew installs the native app;
Home Manager starts it with a launch agent and owns the documented immutable
`~/.config/linearmouse/linearmouse.json`.

The baseline reverses vertical scrolling for devices categorized as mice while
preserving natural trackpad scrolling. Logitech HID++ high-resolution wheel mode
is deliberately off: the connected MX Master 3 advertises support, and enabling
it does produce fine-grained smooth scrolling, but that was tried on 2026-08-13
and rejected as worse in daily use. Off keeps the wheel's discrete, notched
steps. This does not change MagSpeed free-spin, pointer DPI, or the horizontal
thumb wheel.

Home Manager also converges the visible general settings without replacing the
entire preferences domain: show the menu-bar item only when attention is needed,
show battery at 5% or below, hide the Dock icon, and leave pointer-location
highlighting off.

Two of those keys are stored as **JSON strings, with literal double quotes**,
because LinearMouse keeps enums through the `Defaults` library. `mouse.nix`
declares them that way deliberately; removing the quotes silently reverts both
settings to their defaults. See
[the encoding note](../../docs/research/2026-08-13-defaults-library-enum-encoding.md)
before touching them.

Start-at-login is owned by LinearMouse's own setting, not by a Home Manager
launch agent. There was an agent here until 2026-08-13; it raced LinearMouse's
SMAppService login item, which Nix cannot switch off, so both could start the
app and two processes would filter the same mouse events.

The configuration does not guess model-specific device IDs, pointer tuning, or
button mappings. Add exact MX mappings only after observing the real identifiers.

Grant LinearMouse Accessibility permission once. Nix does not bypass macOS TCC.
The app UI is not the source of truth: edit `mouse.nix` and rebuild instead.

Do not run another mouse remapper alongside LinearMouse. Karabiner remains
keyboard-only. SteerMouse is no longer part of the desired configuration; global
Homebrew cleanup still remains `"uninstall"`, not `"zap"`.
