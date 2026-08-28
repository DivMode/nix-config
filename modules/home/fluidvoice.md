# FluidVoice

Local, on-device dictation. The cask is declared in
`modules/darwin/homebrew.nix`; its settings are declared in `fluidvoice.nix` as
`targets.darwin.defaults."com.FluidApp.app"`.

## What Nix owns, and what it must not

Home Manager applies these with `defaults import`, which **merges** into the
domain rather than replacing it. That was verified on 2026-08-27 against the
LinearMouse domain, declared here for weeks and still holding seven keys this
repository never mentions.

The distinction matters more for this application than for most, because the
same domain holds `TranscriptionHistoryEntries` — the text of everything ever
dictated on this Mac, 1.4 MB of it. Nix owns preferences here. It must never
own that, and does not.

Undeclared on purpose, beyond the ordinary application state:

- **Microphone selection.** `PreferredInputDeviceUID`, `PreferredOutputDeviceUID`,
  `MicrophonePriority` and `MicrophoneSelectionMode` name devices by CoreAudio
  UID, and a UID embeds the display's hardware serial. That is machine
  identity: `local.nix` if it is ever wanted, never this public repository.
- **`EnableDebugLogs`.** Currently on. Left as it is rather than declared
  either way, because changing a diagnostic setting nobody asked about does not
  belong in a configuration commit.

## The hotkey

Hyper + S — hold Caps Lock, which `karabiner.nix` emits as
`Ctrl+Opt+Cmd+Shift`, and press S. Declared in `fluidvoice.nix`, applied at
activation, and reproducible on a new machine.

It replaced plain `Shift+S`, which was unusable for the obvious reason: that is
the chord for typing a capital S. Hyper+S is not, because FluidVoice matches on
an **equality** of the relevant modifier set
(`HotkeyShortcut.matches(keyCode:modifiers:)`), and a capital S carries Shift
alone.

### How it is stored, and why it needs its own activation entry

`HotkeyShortcutKey` and `PrimaryDictationShortcuts` are **CFData holding JSON**:

```
{"kind":"keyboard","modifierFlagsRawValue":1966080,"keyCode":1}
```

`1966080` is `shift|control|option|command` as `NSEvent.ModifierFlags` raw
values; `1` is `kVK_ANSI_S`. The schema is FluidVoice's own `HotkeyShortcut`
type in `Sources/Fluid/Models/HotkeyShortcut.swift`, read rather than guessed.

`targets.darwin.defaults` cannot carry it. It renders through
`lib.generators.toPlist`, which has no `<data>` output and no bytes type. So
these two keys are written by `home.activation.installFluidVoiceHotkey` using
`defaults write -data`, ordered after `setDarwinDefaults` so the two writers to
this domain cannot race.

The JSON is generated with `builtins.toJSON` from a typed Nix attribute set, so
what gets reviewed is the structure and the encoding is mechanical — no
hand-authored hex.

The entry compares the **decoded JSON** before writing, so an equivalent
re-encoding does not read as a change, and restarts FluidVoice only when the
shortcut actually changed. The restart is necessary because FluidVoice reads
its preferences at launch and a running process can write its stale in-memory
value back; gating it is what stops every unrelated rebuild killing the
dictation application mid-sentence.

## Why not a modifier-only key

FluidVoice's own default is Right Option, and a modifier-only shortcut is
genuinely better in one way: there is no letter to collide with and none to
auto-repeat. It was rejected for a **left-hand** shortcut specifically, on the
evidence of `Sources/Fluid/Services/GlobalHotkeyManager.swift`.

In `hold` mode a modifier-only shortcut arms with **no threshold**.
`scheduleModifierOnlyStart` calls `behavior.onHoldStart()` directly on the
modifier's key-down; the only tap threshold in that file,
`automaticTapThresholdSeconds = 0.4`, belongs to `automatic` mode. So the
microphone opens the instant the modifier goes down.

That is fine for Right Option, a key this keyboard never otherwise uses. It is
wrong for every left-hand modifier:

| Key | What it would fire on |
| --- | --- |
| Left Option | every `Option+E` accent, every Option-click and Option-drag |
| Left Control | every terminal `Ctrl-C`, `Ctrl-A`, `Ctrl-R` |
| Left Command | essentially every keyboard shortcut on the system |

The press is discarded on release — `wasCleanPress` goes false as soon as
another key joins — but the microphone has already opened. Left-handed and
modifier-only are not compatible here.

## Things that are true and worth not re-deriving

- **Holding the chord does not type `sssss`.** The event tap consumes a
  matching key-down, auto-repeats included: `GlobalHotkeyManager` returns `nil`
  for the primary shortcut.
- **The cost is a Karabiner dependency.** Without it Caps Lock is Caps Lock, so
  dictation stops working AND the keyboard latches into capitals.
  `karabiner.md` records how that chain breaks. It is a dependency this
  keyboard already carries for its arrow keys and its Escape.
- **What other tools default to**, for when this is revisited: FluidVoice ships
  Right Option, Wispr Flow holds Fn, superwhisper uses Option+Space. All three
  are single-purpose keys the user does not otherwise press — the same property
  Hyper+S gets from requiring four modifiers at once.

## Changing it later

Edit `dictationShortcut` in `fluidvoice.nix` and rebuild. Key codes are in
`HotkeyShortcut.keyCodeToString`; modifier raw values are `NSEvent.ModifierFlags`.
There is no need to touch the application's settings window, which is the point.

Verify with:

```
defaults export com.FluidApp.app - | plutil -extract HotkeyShortcutKey raw -o - - | base64 -d
```
