# How the `Defaults` library stores enums, and why the quotes are load-bearing

## Recommendation

An application built on [`sindresorhus/Defaults`](https://github.com/sindresorhus/Defaults)
stores a `Codable` enum as **JSON**, not as its raw value. For a string-backed
enum the JSON encoding of `.whenAttentionNeeded` is the 21-character
`"whenAttentionNeeded"` — quotes included — and that is what belongs in the
plist.

Declare it in Nix with the quotes inside the string:

```nix
targets.darwin.defaults."com.lujjjh.LinearMouse" = {
  menuBarVisibilityMode = ''"whenAttentionNeeded"'';
  menuBarBatteryDisplayMode = ''"below5"'';
  showInDock = false;          # plain Bool: no bridge, no quotes
};
```

This looks like a shell-escaping bug that someone forgot to clean up. It is not.
Removing those quotes on 2026-08-13 is what broke the LinearMouse menu bar icon,
and rediscovering why cost most of a day.

## Why

`Defaults` selects a *bridge* per type, by protocol conformance, in
`Sources/Defaults/Defaults+Extensions.swift`:

```swift
extension Defaults.Serializable where Self: Codable {
    public static var bridge: Defaults.TopLevelCodableBridge<Self> { … }
}
extension Defaults.Serializable where Self: Codable & RawRepresentable {
    public static var bridge: Defaults.RawRepresentableCodableBridge<Self> { … }
}
extension Defaults.Serializable where Self: Codable & RawRepresentable & Defaults.PreferRawRepresentable {
    public static var bridge: Defaults.RawRepresentableBridge<Self> { … }
}
extension Defaults.Serializable where Self: RawRepresentable {
    public static var bridge: Defaults.RawRepresentableBridge<Self> { … }
}
```

Two of those bridges store completely different bytes:

- `RawRepresentableBridge` serialises `value.rawValue` — a bare string.
- `RawRepresentableCodableBridge` is a `CodableBridge`, so it serialises through
  `JSONEncoder` — a quoted JSON string.

Which one applies is decided entirely by whether the type opts into the marker
protocol `Defaults.PreferRawRepresentable`. LinearMouse's enums do not:

```swift
enum MenuBarVisibilityMode: String, Codable, Defaults.Serializable {
    case always
    case whenAttentionNeeded
    case never
}
```

`String` raw value plus `Codable`, no `PreferRawRepresentable` — so
`RawRepresentableCodableBridge`, so JSON, so quotes.

## The failure signature

Write the bare form and nothing errors. `JSONDecoder` simply fails, `Defaults`
returns the key's declared default, and the application carries on. The
fingerprint is a **disagreement between the application's own settings window
and its plist**:

| Where | `menuBarVisibilityMode` | `menuBarBatteryDisplayMode` |
| --- | --- | --- |
| `plutil -p …plist` | `never` | `below5` |
| LinearMouse settings window | `Always` | `Off` |

Those UI values are the declared defaults in `DefaultsKeys.swift`
(`menuBarVisibilityMode` defaults to `.always`, `menuBarBatteryDisplayMode` to
`.off`). Seeing defaults in the UI while the plist holds something else means
the stored value could not be decoded.

The other half of the signature is *which* keys break. In the same domain,
`showInDock` and `showPointerLocation` kept working throughout, because a plain
`Bool` has no bridge and is stored natively. Only the two enum-backed keys
failed. When some keys in a domain apply and others silently don't, suspect
encoding, not permissions and not ordering.

## How to avoid re-deriving this

Do not reason about the encoding from the source. Set the value once in the
application's own UI, then read back exactly what it wrote:

```sh
plutil -p ~/Library/Preferences/com.lujjjh.LinearMouse.plist
```

Declare those bytes. This is now a rule in `AGENTS.md`.

## What this cost, and the diagnostic lesson

The wrong theories chased before the encoding was checked, each of which
survived longer than it should have:

1. **Activation ordering** — the restart and `setDarwinDefaults` really were
   unordered in the same DAG tier, and that really was worth fixing, but it was
   not the cause.
2. **Accessibility gating** — `StatusItem.setup()` genuinely does run inside
   `AccessibilityPermission.pollingUntilEnabled`, so a missing grant would
   explain the symptom. It was disproven in one second by the fact that scroll
   reversal worked.
3. **The battery threshold** — `whenAttentionNeeded` genuinely means only
   "battery at or below the threshold", so a low battery would explain a visible
   icon. The log said `battery=65`.

Every one of those was a plausible mechanism supported by real source code, and
every one was wrong. What actually settled it was a screenshot of the
application's own settings window — the application's view of its state, next to
the stored state. **Compare those two first.** They isolate a decode failure
immediately, and no amount of reading the application's source can substitute
for it.
