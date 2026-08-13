# Logitech keyboard and legacy Karabiner function keys

Date: 2026-08-12

## Recommendation

Remove the recovered `fn_function_keys` table and keep the new configuration free of device-specific entries. Let the Logitech keyboard control its own top-row mode with **Fn+Esc**.

This is not merely a simplification. Karabiner's own Logitech compatibility guidance says an MX Keys keyboard can lose Logitech-specific function-key behavior while Karabiner is running, and recommends an empty `fn_function_keys` array. It specifically calls out Fn+Esc mode switching and the F1-F3 input-switching keys. [Karabiner-Elements: Logitech Logi Options+ compatibility](https://karabiner-elements.pqrs.org/docs/help/troubleshooting/logitech-logi-options-plus-compatibility/)

The currently connected USB device is a Logitech receiver. Its receiver identifier is consistent with a Logi Bolt receiver, but macOS exposes only `USB Receiver`; it does not reveal which paired keyboard model is in use. A receiver can support multiple paired devices, so the receiver alone is not evidence that the keyboard is a particular MX Keys model. The implementation should therefore not encode a model-specific assumption.

## What the five recovered device entries were

The five entries in the 2022 iCloud file were old per-device records, not five settings that every keyboard needs:

1. A Poker II mechanical keyboard with Windows-style modifier swaps, an Application-key-to-Fn mapping, and a Pause-to-Power mapping.
2. An Apple keyboard interface with no custom mappings.
3. A Logitech composite device's keyboard interface, explicitly ignored by Karabiner.
4. The same Logitech composite device's pointing-device interface, also explicitly ignored.
5. Another Logitech receiver keyboard interface, explicitly ignored.

The public repository should not preserve these hardware identifiers. The first entry belongs to an old, explicitly customized keyboard; the remaining entries add no portable behavior. Universal complex modifications—Caps/Escape/Hyper, the Hyper navigation layer, Return/Control, and both-Shifts Caps Lock—should have no device condition unless a real exception is intentionally introduced later. Karabiner supports device conditions when they are actually needed. [Karabiner-Elements: device conditions](https://karabiner-elements.pqrs.org/docs/json/complex-modifications-manipulator-definition/conditions/device/)

The recovered Factorio and Dirt Rally exclusions were application-specific conditions attached to old rules. They are not present in the new Home Manager implementation and should remain excluded.

## What the recovered F1-F12 table did

The old profile forced this Apple-style function row globally:

| Key | Forced action |
| --- | --- |
| F1 | Lower display brightness |
| F2 | Raise display brightness |
| F3 | Mission Control |
| F4 | Launchpad |
| F5 | Lower keyboard backlight |
| F6 | Raise keyboard backlight |
| F7 | Previous/rewind media |
| F8 | Play or pause media |
| F9 | Next/fast-forward media |
| F10 | Mute sound |
| F11 | Lower volume |
| F12 | Raise volume |

That is the traditional Apple function-row layout, not a neutral standard. Apple says top-row keys may operate system features or standard F-keys, and that non-Apple keyboards may use their manufacturer's utility or behavior instead. [Apple: How to use the function keys on your Mac](https://support.apple.com/en-ie/102439)

Logitech documents MX Keys as defaulting to direct media keys, with **Fn+Esc** switching between media keys and standard F-keys. [Logitech: Getting Started — MX Keys](https://support.logi.com/hc/en-ca/articles/360034762774-Getting-Started-MX-Keys) Newer MX Keys S models also have model-specific top-row actions such as Dictation, Emoji, and microphone mute, so imposing the 2022 Apple table could overwrite the labels and native behavior of the actual keyboard. [Logitech: MX Keys S](https://www.logitech.com/en-ae/products/keyboards/mx-keys-s-wireless-keyboard.html)

## Resulting ownership rule

- Karabiner/Home Manager owns the portable complex remaps.
- The Logitech keyboard owns its F-row/media-mode selection through Fn+Esc.
- No recovered device identifiers, ignored-device records, or game exceptions belong in the public Nix configuration.
- Do not install Logi Options+ merely to reproduce this function-row behavior. Reconsider it only if a model-specific feature is later required and has no firmware-level control.
