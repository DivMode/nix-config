# Mouse configuration

LinearMouse is the sole mouse-event owner. Homebrew installs the native app;
LinearMouse's own login item starts it, and Home Manager owns the documented
`~/.config/linearmouse/linearmouse.json` — written as a real file, in place, so
the app's watcher sees the change and so its settings window can still save.

The baseline reverses vertical scrolling for devices categorized as mice while
preserving natural trackpad scrolling. Logitech HID++ high-resolution wheel mode
is deliberately off: the connected MX Master 3 advertises support, and enabling
it does produce fine-grained smooth scrolling, but that was tried on 2026-08-13
and rejected as worse in daily use. Off keeps the wheel's discrete, notched
steps. This does not change MagSpeed free-spin, pointer DPI, or the horizontal
thumb wheel.

It was tried a second time between 2026-08-13 and 2026-08-21, that time paired
with a tuned `scrolling.smoothed` engine on a receiver-specific scheme, and
rejected again. Both attempts are worth knowing about, because the second one
looked like a tuning problem and was not: discrete clicks are the thing wanted,
and removing them is precisely what the smoothed engine is for. There is no
value of inertia, response, or speed that produces a detent. The knob is
`logitech.highResolutionWheel`, and it stays off.

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

Logi Options+ is the one declared exception, and it is not a remapper here. The
MagSpeed wheel has two MECHANICAL modes — ratchet and free-spin — and they are a
HID++ feature of the mouse firmware, not an event stream anything on this Mac can
filter. LinearMouse cannot reach them, which the research note above states
outright, so a wheel stuck in free-spin cannot be fixed from this repository. On
2026-08-21 that cost most of a day: the smooth scrolling was assumed to be the
declared `scrolling.smoothed` engine, the engine was removed, and the wheel still
had no detents, because the two are unrelated.

Every alternative was checked first. logiops, logiops-rs and OpenLogi handle
SmartShift but are Linux-only; Mouser, mx3-lite, optune and nibble run on macOS
but do not expose it; SteerMouse remaps input events and cannot touch a firmware
feature. Logi Options+ is the only macOS tool that can, which is the whole
justification for a second mouse daemon.

The mode is stored on the mouse, so Options+ may be usable as a one-time
configuration tool: set ratchet, confirm it survives, then remove the cask and
let strict cleanup uninstall it. Verify before depending on that. If it is kept,
it needs Accessibility and Input Monitoring approval, which stays manual.
