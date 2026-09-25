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
`Ctrl+Opt+Cmd+Shift`, and press S. Karabiner turns that chord into **Right
Option**, held for as long as S is held, and FluidVoice's stored shortcut is
Right Option, modifier-only. The physical Right Option key starts dictation too.

### Why Karabiner owns the chord and FluidVoice only hears Right Option

FluidVoice detects its shortcut with a CGEventTap. While any application holds
**Secure Event Input**, macOS withholds key-down events from every event tap. A
letter chord like Hyper+S then stops working until that application lets go.
Only the application that enabled secure input can disable it. On 2026-09-24,
`kCGSSessionSecureInputPID` named ChatGPT.app, and the state outlived that
process. 1Password is widely reported doing the same.

Measured the same day, with a listen-only tap while secure input was forced on
by `EnableSecureEventInput()`: Hyper+S delivered **zero** keyDown events, while
every Hyper modifier's `flagsChanged` event still arrived. With this
arrangement, dictation then worked end to end with secure input still on.

Karabiner reads the keyboard at the HID layer, below event taps, so secure
input does not affect its rules. FluidVoice cannot be triggered by Karabiner
directly: it has no URL scheme or supported external trigger (its
`com.FluidApp.debug.toggleRecording` notification is a diagnostics-only
toggle, inert unless a debug default is set, and cannot do hold-to-talk). So
FluidVoice still needs *a* key, and the only kind that survives secure input is
a modifier. Right Option is the one modifier this keyboard never otherwise
uses.

Hyper+S was chosen originally over plain `Shift+S`, which fired on every
capital S.

### How it is stored, and why it needs its own activation entry

`HotkeyShortcutKey` and `PrimaryDictationShortcuts` are **CFData holding JSON**:

```
{"keyCode":61,"kind":"keyboard","modifierFlagsRawValue":0,"modifierKeyCodes":[61]}
```

`61` is `kVK_RightOption`. For a modifier-only shortcut FluidVoice stores the
trigger in `modifierKeyCodes` and subtracts its own flag from the modifier
flags, leaving `0`. The schema is FluidVoice's own `HotkeyShortcut`
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

## Why Right Option and not a left-hand modifier

FluidVoice's own default is Right Option. A modifier-only shortcut is
required here anyway (secure input, above), but a **left-hand** one is wrong, on
the evidence of `Sources/Fluid/Services/GlobalHotkeyManager.swift`.

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

- **Holding the chord does not type `sssss`.** Karabiner consumes the S and
  emits only Right Option, which does not auto-repeat.
- **The cost is a Karabiner dependency.** Without it Caps Lock is Caps Lock, so
  dictation stops working AND the keyboard latches into capitals.
  `karabiner.md` records how that chain breaks. It is a dependency this
  keyboard already carries for its arrow keys and its Escape.
- **What other tools default to**, for when this is revisited: FluidVoice ships
  Right Option, Wispr Flow holds Fn, superwhisper uses Option+Space. All three
  are single-purpose keys the user does not otherwise press.

## Changing it later

Edit `dictationShortcut` in `fluidvoice.nix` and rebuild. Key codes are in
`HotkeyShortcut.keyCodeToString`; modifier raw values are `NSEvent.ModifierFlags`.
There is no need to touch the application's settings window, which is the point.

Verify with:

```
defaults export com.FluidApp.app - | plutil -extract HotkeyShortcutKey raw -o - - | base64 -d
```
