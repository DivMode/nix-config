# Declarative macOS mouse configuration to replace SteerMouse

## Recommendation

Use **LinearMouse** as the single owner of mouse scrolling, pointer behavior, and
button mappings. Install its Homebrew cask through nix-darwin, generate its
documented JSON configuration from Nix, and have Home Manager link that file at
`~/.config/linearmouse/linearmouse.json`. Remove SteerMouse only as part of the
same reviewed switch so that two input tools never handle the mouse concurrently.

LinearMouse is the strongest match for this repository because its configuration
is a documented, schema-backed JSON interface rather than an opaque GUI export.
Its current configuration language can:

- match all mice by `device.category = "mouse"`, leaving an Apple trackpad alone;
- reverse vertical or horizontal scrolling independently;
- match a particular device by vendor ID and product ID;
- set pointer speed and acceleration (including disabling acceleration);
- match applications and displays;
- remap ordinary mouse buttons, scroll gestures, and Logitech HID++ controls; and
- enable high-resolution scrolling on supported Logitech mice.

These are first-class fields in the project's
[configuration reference](https://github.com/linearmouse/linearmouse/blob/984333200f1c868638a72e83ff186bb56b5aa8ec/Documentation/Configuration.md)
and its published
[typed schema](https://github.com/linearmouse/linearmouse/blob/984333200f1c868638a72e83ff186bb56b5aa8ec/Documentation/Configuration.d.ts).
The official site specifically advertises keeping natural scrolling on the
trackpad while reversing it on the mouse, per-device/app/display profiles,
pointer tuning, and button mappings. ([LinearMouse](https://linearmouse.app/))

The currently published release is 0.11.4 (2 August 2026), and its versioned JSON
schema is available at `https://schema.linearmouse.app/0.11.4`.
([release](https://github.com/linearmouse/linearmouse/releases/tag/v0.11.4),
[schema](https://schema.linearmouse.app/0.11.4))

## Declarative ownership and reload behavior

LinearMouse documents `~/.config/linearmouse/linearmouse.json` as its canonical
configuration file. If no file exists, it creates an empty one. The application
loads that JSON directly and watches both the canonical path and its older
Application Support path with FSEvents. An external change is debounced and
reloaded automatically. Its watcher deliberately resolves symlinks and watches
both the lexical and resolved locations. These behaviors are visible in the
project's
[`ConfigurationState`](https://github.com/linearmouse/linearmouse/blob/984333200f1c868638a72e83ff186bb56b5aa8ec/LinearMouse/State/ConfigurationState.swift)
and
[`FileWatcher`](https://github.com/linearmouse/linearmouse/blob/984333200f1c868638a72e83ff186bb56b5aa8ec/LinearMouse/Utilities/FileWatcher.swift)
implementations.

That makes a Home Manager-owned file appropriate for a **configuration-as-code,
no-GUI-editing** workflow:

1. Nix generates valid JSON containing a versioned `$schema` and `schemes`.
2. Home Manager owns `.config/linearmouse/linearmouse.json` as a Nix-store
   symlink.
3. LinearMouse reads it and hot-reloads when a new Home Manager generation changes
   the target.
4. UI edits are intentionally not a supported source of truth.

There is one important consequence: LinearMouse's settings UI attempts to write
configuration changes atomically after resolving symlinks. A Home Manager link
therefore points its write at the read-only Nix store and the write will fail.
That is desirable for this user's explicit no-UI requirement because it prevents
configuration drift, but it must be documented. If GUI editing is ever wanted,
the alternative is an activation-time **copy** to a writable runtime file; that
would be reproducible at activation but no longer continuously immutable.
([configuration serializer](https://github.com/linearmouse/linearmouse/blob/984333200f1c868638a72e83ff186bb56b5aa8ec/LinearMouse/Model/Configuration/Configuration.swift))

LinearMouse's “start at login” checkbox uses macOS login-item state, not the JSON
file. To keep startup declarative, do not use that checkbox. Define a Home Manager
`launchd.agents` entry that starts
`/Applications/LinearMouse.app/Contents/MacOS/LinearMouse` at login. The first run
still requires the macOS Accessibility approval that all event-rewriting mouse
utilities need; macOS privacy approval is machine state, not safe public-repo
configuration.

The official installation command is `brew install --cask linearmouse`, so the
cask fits the repository's existing nix-darwin-owned Homebrew policy.
([official site](https://linearmouse.app/),
[Homebrew cask](https://formulae.brew.sh/cask/linearmouse))

## Initial portable configuration

The portable first version should match the **mouse category**, not a receiver's
vendor/product ID. That expresses the actual desired behavior and continues to
work whether the Logitech MX mouse uses Bluetooth, a Bolt receiver, or another
receiver:

```json
{
  "$schema": "https://schema.linearmouse.app/0.11.4",
  "schemes": [
    {
      "if": {
        "device": { "category": "mouse" }
      },
      "scrolling": {
        "reverse": { "vertical": true }
      }
    }
  ]
}
```

This is the official documentation's minimal example. It reverses only mouse
vertical scrolling, so the macOS global natural-scrolling setting can remain on
for the trackpad. Add pointer tuning or buttons only after observing the exact
MX control identifiers; guessed button IDs do not belong in a rebuildable public
configuration. Device-specific matching remains available when there is a real
exception. ([configuration reference](https://github.com/linearmouse/linearmouse/blob/984333200f1c868638a72e83ff186bb56b5aa8ec/Documentation/Configuration.md))

## Alternatives considered

| Tool | Declarative fit | Relevant capability | Why it is not the recommendation |
| --- | --- | --- | --- |
| **LinearMouse** | Excellent: documented JSON, versioned schema, external-change hot reload, symlink-aware watcher | Separate mouse/trackpad direction, pointer tuning, per-device/app/display profiles, buttons, current Logitech HID++ support | Recommended. UI writes must be avoided with an immutable Home Manager file. |
| **Karabiner-Elements** | Excellent: this repository already generates its entire JSON config from Nix | `mouse_basic` can flip vertical/horizontal wheels with `device_if`; pointing buttons can be mapped | Best minimal alternative, but mice are disabled by default and must be explicitly grabbed. It is primarily a keyboard remapper and offers less mouse acceleration/smoothing/HID++ control than LinearMouse. Expanding its input ownership while diagnosing system-wide input stalls is unnecessary risk. ([mouse buttons](https://karabiner-elements.pqrs.org/docs/help/how-to/mouse-button/), [`mouse_basic`](https://karabiner-elements.pqrs.org/docs/json/complex-modifications-manipulator-definition/other-types/mouse-basic/), [device conditions](https://karabiner-elements.pqrs.org/docs/json/complex-modifications-manipulator-definition/conditions/device/)) |
| **Mos** | Weak-to-moderate: settings are private `UserDefaults` keys and encoded data, not a documented public config interface | Smooth/reverse scrolling, per-app profiles, buttons, and recent native Logitech HID++ support | Capable, but its official user interface is the supported configuration path. The source persists settings in `UserDefaults`; there is no documented, versioned config contract suitable for hand-authored Nix. ([official README](https://github.com/Caldis/Mos/blob/e5565f3fb2a90881d8d6b3b2c492ed2a36a469e3/README.enUS.md), [persistence source](https://github.com/Caldis/Mos/blob/e5565f3fb2a90881d8d6b3b2c492ed2a36a469e3/Mos/Options/Options.swift)) |
| **Mac Mouse Fix** | Poor: mutable application-support plist with application state/license data; no documented declarative contract | Scrolling and gestures for ordinary mice | Its maintainer says mouse-specific settings are not yet available and some Logitech devices' proprietary buttons cannot be recognized. It also lacks pointer-acceleration control. ([official repository](https://github.com/noah-nuebling/mac-mouse-fix)) |
| **BetterMouse** | Poor: commercial, UI-first, only import/export of its own config is documented | Broad MX hardware, wheel, pointer, and button control | It documents no stable JSON/plist/CLI configuration API. Its own troubleshooting says malformed configuration can cause malfunctions and vertical inversion may require a restart. That is not an acceptable declarative interface. ([official site](https://better-mouse.com/)) |
| **SteerMouse** | Poor: opaque mutable `Device.smsetting`, manual license, GUI reconfigure | Broad per-device commercial driver support | Already rejected by the user; its runtime profile must be copied rather than safely kept as an immutable Home Manager link. |
| **Logi Options+** | Poor: GUI/database state and proprietary background services | Complete vendor-specific MX feature set | Logitech documents button, gesture, wheel, speed and app-specific customization, but exposes no supported config-as-code interface. ([Logitech Options+](https://www.logitech.com/en-us/software/options.html)) |

## Safe replacement sequence

1. Add the `linearmouse` cask and the generated JSON/launch agent in one reviewed
   Nix change.
2. Remove the `steermouse` cask, SteerMouse licensing instructions, secrets
   documentation, and claims that it owns mouse behavior in that same change.
3. Build and check the flake without activating it.
4. Quit SteerMouse before the first activation so only one process rewrites mouse
   events.
5. Activate, grant LinearMouse Accessibility once, and verify mouse wheel direction
   while confirming trackpad direction remains natural.
6. Observe actual Logitech controls before declaring any button mapping.
7. Do not add Mos, Mac Mouse Fix, BetterMouse, or Logi Options+ alongside it.

This replacement is independent of the current keyboard/input-lag diagnosis.
Changing mouse software cannot be presented as a fix for keyboard stalls or
premature push-to-talk release events.
