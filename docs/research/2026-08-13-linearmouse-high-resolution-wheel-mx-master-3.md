# LinearMouse high-resolution scrolling on Logitech MX Master 3

## Recommendation

The Logitech MX Master 3 supports LinearMouse's high-resolution wheel mode, and
LinearMouse 0.11.4—the version installed on this Mac—contains the stable
receiver-capable implementation. It is reasonable and safe to declare the
feature, but **the current reverse-only profile will not produce a noticeably
smoother scroll by itself**. LinearMouse intentionally combines the finer
substeps back into normal detents when scroll distance is automatic and
smoothed scrolling is disabled.

The correct schema-backed setting is:

```json
{
  "if": {
    "device": { "category": "mouse" }
  },
  "logitech": {
    "highResolutionWheel": true
  },
  "scrolling": {
    "reverse": { "vertical": true }
  }
}
```

The exact field is `logitech.highResolutionWheel`, a boolean described by the
official typed schema as enabling finer vertical wheel steps on supported
Logitech HID++ mice. The application's own UI uses the same description.
([typed schema](https://github.com/linearmouse/linearmouse/blob/984333200f1c868638a72e83ff186bb56b5aa8ec/Documentation/Configuration.d.ts#L449-L455),
[UI source](https://github.com/linearmouse/linearmouse/blob/984333200f1c868638a72e83ff186bb56b5aa8ec/LinearMouse/UI/ScrollingSettings/LogitechHighResolutionWheelSection.swift#L10-L17))

Using the existing mouse-category scheme is valid. Unsupported mice cannot
construct LinearMouse's Logitech HID++ controller, so the attempted setting has
no hardware effect. A separate scheme matched by Logitech vendor ID `0x046d`
would express the scope more narrowly, but it is not required for correctness
and would not improve MX Master 3 behavior.

Do not add smoothed scrolling silently. It changes the wheel's feel, momentum,
and bounce behavior. If visibly finer motion is wanted after trying this
baseline, make smoothing or an explicit pixel distance a separate, deliberate
setting.

## What “high resolution” means

This setting changes the **electronic scroll reports** produced by the mouse. It
does not increase display resolution, pointer DPI, polling rate, or the physical
wheel's number of ratchet notches.

LinearMouse discovers the Logitech HID++ `HIRES_WHEEL` feature, reads the
device-reported step multiplier, and changes only the high-resolution mode bit
(`0x02`). The finer reports allow software to react to sub-detent wheel motion.
LinearMouse remembers the pre-existing hardware mode and restores it when the
application exits.
([controller](https://github.com/linearmouse/linearmouse/blob/984333200f1c868638a72e83ff186bb56b5aa8ec/LinearMouse/Device/VendorSpecific/Logitech/LogitechHIDPPHighResolutionWheelController.swift#L6-L87),
[apply and restore behavior](https://github.com/linearmouse/linearmouse/blob/984333200f1c868638a72e83ff186bb56b5aa8ec/LinearMouse/Device/Device%2BHighResolutionWheel.swift#L42-L143))

The control is shown in LinearMouse only after the connected device successfully
reports support. The implementation accepts Logitech HID++ devices over direct
Bluetooth Low Energy or USB receiver transports and resolves classic,
LightSpeed, and Bolt receiver slots.
([feature resolver](https://github.com/linearmouse/linearmouse/blob/984333200f1c868638a72e83ff186bb56b5aa8ec/LinearMouse/Device/VendorSpecific/Logitech/LogitechHIDPPFeatureTargetResolver.swift#L12-L85),
[visibility check](https://github.com/linearmouse/linearmouse/blob/984333200f1c868638a72e83ff186bb56b5aa8ec/LinearMouse/UI/ScrollingSettings/ScrollingSettingsState.swift#L64-L80))

The initial feature was merged in June 2026. Stable 0.11.4 added receiver
support; the LinearMouse maintainer specifically tested the receiver path with
an MX Master 3S and verified that the mode could be read, toggled, and restored.
The same HID++ high-resolution feature is present in the MX Master family.
([initial implementation PR](https://github.com/linearmouse/linearmouse/pull/1247),
[Bolt receiver PR and MX Master 3S test](https://github.com/linearmouse/linearmouse/pull/1284),
[0.11.4 release](https://github.com/linearmouse/linearmouse/releases/tag/v0.11.4))

## It is separate from MagSpeed and SmartShift

The MX Master 3's physical MagSpeed wheel has two mechanical-feel modes:
line-by-line ratchet and near-frictionless free-spin. SmartShift automatically
changes from ratchet to free-spin based on wheel speed, while the button on top
can change modes manually. Logitech documents those controls separately.
([Logitech MX Master 3 guide](https://support.logi.com/hc/en-ca/articles/360035271133-Getting-Started-MX-Master-3))

LinearMouse's `highResolutionWheel` flag does **not** configure SmartShift,
SmartShift sensitivity, ratchet mode, free-spin mode, or the top mode-shift
button. Its controller modifies only the HID++ high-resolution bit while
preserving the other wheel-mode bits. The physical wheel can therefore remain
in either ratchet or free-spin while high-resolution reporting is enabled.

## Interaction with the other scrolling settings

LinearMouse's event pipeline applies these operations in this order:

1. Reverse vertical or horizontal deltas.
2. Normalize high-resolution Logitech wheel reports when necessary.
3. Apply smoothed scrolling or explicit line/pixel distance.
4. Apply the older non-smoothed speed and acceleration settings.

The order is visible in the official event-transformer construction.
([pipeline source](https://github.com/linearmouse/linearmouse/blob/984333200f1c868638a72e83ff186bb56b5aa8ec/LinearMouse/EventTransformer/EventTransformerManager.swift#L750-L867))

Consequences:

- **Reverse scrolling:** fully compatible. Reversal changes sign before the
  high-resolution reports are normalized.
- **Current `auto` distance, no smoothing:** LinearMouse deliberately accumulates
  substeps into ordinary detents. High-resolution mode is safe but offers little
  or no visible smoothness by itself.
- **Explicit line or pixel distance:** the linear transformer consumes the
  reported multiplier and retains the appropriate fine-grained movement.
- **Smoothed scrolling:** the smoothing engine consumes the fine events and
  device multiplier directly. This is where high resolution can make changes in
  direction feel more responsive, but smoothing also adds configurable response,
  inertia, speed, acceleration, and optional rubber-band bouncing.
- **Speed and acceleration:** ordinary `scrolling.speed` and
  `scrolling.acceleration` are used only when smoothing is absent. With smoothing,
  use the corresponding fields inside `scrolling.smoothed`.

The normalizer's mode selection and event accumulation are explicit in the
source.
([mode selection](https://github.com/linearmouse/linearmouse/blob/984333200f1c868638a72e83ff186bb56b5aa8ec/LinearMouse/EventTransformer/EventTransformerManager.swift#L920-L933),
[normalizer](https://github.com/linearmouse/linearmouse/blob/984333200f1c868638a72e83ff186bb56b5aa8ec/LinearMouse/EventTransformer/LogitechHighResolutionWheelNormalizer.swift#L38-L104),
[smoothed-scroll schema](https://github.com/linearmouse/linearmouse/blob/984333200f1c868638a72e83ff186bb56b5aa8ec/Documentation/Configuration.d.ts#L208-L287))

## General settings shown in the screenshot

These controls are application preferences, not fields in
`linearmouse.json`. LinearMouse stores them in the macOS preferences domain
`com.lujjjh.LinearMouse`:

| UI setting | Desired value | Preference representation |
| --- | --- | --- |
| Show in menu bar | When needed | `menuBarVisibilityMode` encoded enum value `whenAttentionNeeded` |
| Show current battery | 5% or below | `menuBarBatteryDisplayMode` encoded enum value `below5` |
| Show in Dock | Off | `showInDock = false` |
| Show pointer location | Off | `showPointerLocation = false` |

The enum cases, preference keys, defaults, and UI mappings are defined in
LinearMouse's source.
([preference definitions](https://github.com/linearmouse/linearmouse/blob/984333200f1c868638a72e83ff186bb56b5aa8ec/LinearMouse/DefaultsKeys.swift#L8-L38),
[preference keys](https://github.com/linearmouse/linearmouse/blob/984333200f1c868638a72e83ff186bb56b5aa8ec/LinearMouse/DefaultsKeys.swift#L77-L94),
[General settings UI](https://github.com/linearmouse/linearmouse/blob/984333200f1c868638a72e83ff186bb56b5aa8ec/LinearMouse/UI/GeneralSettings/GeneralSettings.swift#L8-L61))

The enum values are Codable values stored by the Swift `Defaults` package; they
are JSON-string encoded inside the plist string. An activation script must
therefore preserve the embedded quotation marks instead of writing a bare enum
word.

“Start at login” is different again: LinearMouse uses Apple's service-management
login-item mechanism through the LaunchAtLogin library, not JSON or a normal
UserDefaults key.
([General settings source](https://github.com/linearmouse/linearmouse/blob/984333200f1c868638a72e83ff186bb56b5aa8ec/LinearMouse/UI/GeneralSettings/GeneralSettings.swift#L48-L53),
[application migration](https://github.com/linearmouse/linearmouse/blob/984333200f1c868638a72e83ff186bb56b5aa8ec/LinearMouse/AppDelegate.swift#L20-L27))

This repository already uses the more appropriate declarative owner: Home
Manager installs a `launchd` agent with `RunAtLoad = true`. The GUI checkbox does
not need to be enabled and should not become a second startup mechanism.

## Final decision

Keep `logitech.highResolutionWheel = true` for the MX Master 3. It is supported,
schema-valid, harmless for unsupported mouse devices, independent of reverse
scrolling, and restored safely when LinearMouse exits. Treat it as enabling the
hardware's finer input data—not as a promise of smoother visible movement under
the current automatic-distance profile.

Leave smoothing, scroll distance, acceleration, and speed unchanged for now.
After using the baseline, choose a smoothing curve or explicit pixel distance
only if finer visible scrolling is actually wanted.
