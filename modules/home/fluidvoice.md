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

## Changing the hotkey

The shortcut keys are **CFData holding JSON**, not plain values:

```
HotkeyShortcutKey          = {"kind":"keyboard","modifierFlagsRawValue":131072,"keyCode":1}
PrimaryDictationShortcuts  = [{"kind":"keyboard","modifierFlagsRawValue":131072,"keyCode":1}]
HotkeyMode                 = "hold"
```

`131072` is `NSEventModifierFlagShift`; keyCode `1` is `S`.

Two rules apply, and they point the same way:

1. `AGENTS.md` forbids hand-deriving the stored form of anything that is not a
   plain bool, string or integer. Set it in FluidVoice's own settings window,
   read the bytes back, declare exactly those.
2. Nix cannot express it anyway. `targets.darwin.defaults` renders through
   `lib.generators.toPlist`, which has no `<data>` output and no bytes type.

So declaring a shortcut needs an activation entry using
`defaults write com.FluidApp.app <key> -data <hex>`, ordered
`entryAfter [ "setDarwinDefaults" ]` the way `mouse.nix` orders its restart.
That entry is not written yet, because the value it would carry has not been
chosen.

`HotkeyMode`, `PressAndHoldMode` and `PromptModeShortcutEnabled` are withheld
alongside it as one cluster. They describe how the shortcut fires, and
declaring half a shortcut is how the application and this file end up
disagreeing — the failure `mouse.nix` documents at length.

### Procedure

1. Set the shortcut in FluidVoice > Settings.
2. Read back exactly what it stored:

   ```
   plutil -p ~/Library/Preferences/com.FluidApp.app.plist | grep -iE 'Hotkey|Shortcut|PressAndHold'
   ```

3. Declare those bytes, then rebuild.

FluidVoice reads its preferences at launch, so a changed value applies at its
next start. There is deliberately no activation restart: killing the dictation
application mid-sentence to apply a preference is the worse trade.

## Choosing a shortcut

Avoid `Shift` plus a letter. That was the setting until 2026-08-27, on
`Shift+S`, which is the same chord as typing a capital S — the two cannot
coexist.

A modifier-only shortcut avoids the whole class of problem: there is no
character to collide with and none to auto-repeat while the key is held.
FluidVoice supports them (`ModifierOnlyShortcutBehavior`,
`activeModifierOnlyShortcut`, `modifierPressStartTime` in the binary) and its
own default is Right Option, per its shortcut recorder's placeholder text.

A Karabiner Hyper chord — hold Caps Lock, which `karabiner.nix` emits as
`Ctrl+Opt+Cmd+Shift` — also works and never collides with typing, since a
capital letter carries only one of those four modifiers. It costs a dependency:
without Karabiner running, Caps Lock is Caps Lock, so dictation stops working
AND the keyboard latches into capitals. `karabiner.md` records how easily that
chain breaks.
