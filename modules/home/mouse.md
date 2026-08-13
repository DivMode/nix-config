# Mouse configuration

LinearMouse is the sole mouse-event owner. Homebrew installs the native app;
Home Manager starts it with a launch agent and owns the documented immutable
`~/.config/linearmouse/linearmouse.json`.

The baseline reverses vertical scrolling for devices categorized as mice while
preserving natural trackpad scrolling. It does not guess model-specific device
IDs, pointer tuning, or button mappings. Add exact MX mappings only after
observing the real identifiers.

Grant LinearMouse Accessibility permission once. Nix does not bypass macOS TCC.
The app UI is not the source of truth: edit `mouse.nix` and rebuild instead.

Do not run another mouse remapper alongside LinearMouse. Karabiner remains
keyboard-only. SteerMouse is no longer part of the desired configuration; global
Homebrew cleanup still remains `"uninstall"`, not `"zap"`.
