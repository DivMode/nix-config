# Mouse configuration

LinearMouse is the sole mouse-event owner. Homebrew installs the native app;
LinearMouse's own login item starts it, and Home Manager owns the documented
`~/.config/linearmouse/linearmouse.json` — written as a real file, in place, so
the app's watcher sees the change and so its settings window can still save.

The mouse is a Logitech G502 X. It keeps its DPI levels and button assignments
in onboard memory, so it works with no Logitech software running, and nothing
here configures DPI or buttons; change them once with G HUB on any computer if
ever needed. LinearMouse's only job is the one macOS cannot do on its own:
reverse vertical scrolling for devices categorized as mice while trackpads keep
natural scrolling (macOS has a single switch for both).

The configuration used to carry MX Master specifics: Logitech HID++
high-resolution wheel mode, tried twice in August 2026 and rejected both times
in favour of discrete, notched steps. With the G502 that setting no longer
applies and has been removed; do not reintroduce smoothed or high-resolution
wheel scrolling without asking.

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
button mappings; the G502 X keeps those in its onboard memory.

Grant LinearMouse Accessibility permission once. Nix does not bypass macOS TCC.
The app UI is not the source of truth: edit `mouse.nix` and rebuild instead.

Do not run another mouse remapper alongside LinearMouse. Karabiner remains
keyboard-only. SteerMouse is no longer part of the desired configuration; global
Homebrew cleanup still remains `"uninstall"`, not `"zap"`.

Logi Options+ is not installed. It was declared only for the MX Master's
MagSpeed ratchet (a HID++ firmware feature LinearMouse cannot reach), and the
G502 X that replaced that mouse has a physical ratchet switch. It was removed
on 2026-09-24 because it also opened every keyboard's HID interface with
exclusive access: `ioreg -l -r -c IOHIDDevice` showed `ClientSeized=Yes` for
`logioptionsplus_agent` on the Apple Magic Keyboard and both Logitech
receivers, and Karabiner's Caps Lock Hyper did nothing on the Magic Keyboard.
Do not reinstall it alongside Karabiner.
