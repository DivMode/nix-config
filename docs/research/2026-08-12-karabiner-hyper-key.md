# Karabiner-Elements: Caps Lock Hyper key and real Caps Lock

Research date: 2026-08-12

## Recommendation

Use a deliberately small configuration:

1. Hold `Caps Lock` to emit the four-modifier Hyper chord: Control + Option +
   Command + Shift.
2. Press **left Shift and right Shift together** to toggle real Caps Lock.
3. Preserve the established behavior: tap `Caps Lock` to send Escape.
4. Configure Raycast commands with ordinary four-modifier shortcuts and disable
   Raycast's own Caps Lock Hyper-key feature. Karabiner, not Raycast, should be the
   single owner of the physical Caps Lock remap.
5. Preserve the reusable mappings recovered from the legacy configuration:
   Hyper+I/J/K/L navigation, tap/hold Return, physical Escape as backtick/tilde,
   but leave the Logitech-owned function-key row untouched.
6. Do not preserve device identifiers, old game exclusions, the obsolete
   Terminal/iTerm/MacVim-specific rule, application launch shell commands, or
   mouse rules.

This is a fully declarative public configuration: no secret or machine identifier
is needed for these rules.

## “Both Shift keys” is not “double-tap Shift”

There are two different community patterns:

- **Both Shift keys together:** hold either Shift, then press the other. The
  maintained rule in the Karabiner project's community-rules repository handles
  both orders and sends a 200 ms Caps Lock event. The existing Caps Lock state is
  allowed as an optional modifier, so the same chord toggles Caps Lock both on and
  off. This is the intended rule for this repository.
- **Double-tap right Shift:** tap and release right Shift twice within a delayed
  action window. The community “Hyper Key Power Pack” uses a state variable for
  this. It is a different gesture and is easier to trigger while typing, so it is
  not recommended here.

The both-Shift rule does not affect normal use of either Shift alone. Its tradeoff
is that intentionally holding both Shift keys toggles Caps Lock instead of acting
as two redundant Shift modifiers. ([maintained both-Shift rule](https://github.com/pqrs-org/KE-complex_modifications/blob/9aad25469905fb75e2d3b89148bcfb3da38660ee/public/json/press_left_shift_and_right_shift_together_to_toggle_caps_lock.json),
[Karabiner `from.simultaneous` timing documentation](https://karabiner-elements.pqrs.org/docs/json/complex-modifications-manipulator-definition/from/simultaneous/))

The maintained rule does not actually use `from.simultaneous`; it defines both
possible orders as two ordinary manipulators. That avoids changing Karabiner's
global 50 ms simultaneous-key threshold.

## Exact Hyper semantics

Karabiner represents the four-modifier chord by sending one modifier key with the
other three in its `modifiers` array. The project-maintained Caps Lock rules use:

```json
{
  "key_code": "left_shift",
  "modifiers": ["left_command", "left_control", "left_option"]
}
```

That output is Command + Control + Option + Shift; array order has no behavioral
meaning. The rule applies while Caps Lock is held and releases the synthetic
modifiers when Caps Lock is released. ([maintained Caps Lock rules](https://github.com/pqrs-org/KE-complex_modifications/blob/9aad25469905fb75e2d3b89148bcfb3da38660ee/public/json/caps_lock.json))

Karabiner's official documentation explicitly lists “change Caps Lock to
command+control+option+shift” as a standard complex-modification example.
([complex modifications guide](https://karabiner-elements.pqrs.org/docs/manual/configuration/configure-complex-modifications/))

### Tap behavior

The official community set offers three relevant choices: tap Caps Lock for real
Caps Lock, tap it for Escape, or make it Hyper without a tap action. Because real
Caps Lock is available through both Shift keys, tap-for-Escape preserves the
user's established muscle memory without removing access to Caps Lock. It changes
a key-up event and introduces timeout sensitivity. Karabiner says
`to_if_alone` fires on release, is canceled by another keyboard/mouse/scroll event,
and defaults to a 1000 ms timeout unless overridden. Use an explicit 200 ms
timeout and `lazy = true` for the generated modifier.
([`to_if_alone` semantics](https://karabiner-elements.pqrs.org/docs/json/complex-modifications-manipulator-definition/to-if-alone/))

## Evidence from the Nix repositories already reviewed

- **Wimpy does not configure Karabiner.** A full-tree search of
  `wimpysworld/nix-config` at commit
  `97efaed821fcbae491b33231ec62753c127b44c3` found no Karabiner module or Hyper-key
  rule. Wimpy remains a good structural reference for nix-darwin/Home Manager, but
  there is no keyboard rule to copy from that repository.
  ([Wimpy snapshot](https://github.com/wimpysworld/nix-config/tree/97efaed821fcbae491b33231ec62753c127b44c3))
- **The likely remembered repository is `khaneliman/khanelinix`.** It generates
  `karabiner.json` from Nix, uses a 200 ms tap timeout, maps tapped Caps Lock to
  Escape and held Caps Lock to Control on the built-in keyboard, maps right Command
  to a Hyper layer, and adds Vim-style navigation. This demonstrates the desired
  declarative pattern, but its chosen keys and navigation layer do not match this
  Mac's requested behavior and should not be copied wholesale.
  ([Khanelinix configuration](https://github.com/khaneliman/khanelinix/blob/10781d1181a4d0eba195c1a7a7dc377f04d956e2/modules/home/system/input/karabiner.nix))
- `dustinlyons/nixos-config` uses nix-darwin's simpler Caps Lock-to-Control option,
  not Karabiner Hyper. The other previously reviewed popular macOS Nix repositories
  did not provide a closer matching declarative Hyper configuration.

The strongest rule source is therefore the official Karabiner community-rules
repository, with Khanelinix used only as evidence that generating JSON with Nix is
a maintained real-world pattern.

## Installation and declarative ownership

Karabiner-Elements is a native macOS application with background services and a
DriverKit virtual keyboard. Its own GitHub README supports installation with
`brew install --cask karabiner-elements`. That matches this repository's existing
boundary: Homebrew owns native Mac apps and Home Manager owns user configuration.
Do **not** also enable `services.karabiner-elements` in nix-darwin, because that
would create two package owners. The nix-darwin service exists and defaults to the
Nix package, but it is an alternative installation path, not something to combine
with the Homebrew cask. ([Karabiner repository](https://github.com/pqrs-org/Karabiner-Elements),
[nix-darwin options](https://nix-darwin.github.io/nix-darwin/manual/#opt-services.karabiner-elements.enable))

Karabiner's canonical configuration is
`~/.config/karabiner/karabiner.json`. Its documentation warns that linking only
the JSON file prevents file-change detection; if a symlink is used, link the
**whole `~/.config/karabiner` directory**. This means a common Home Manager pattern
such as `xdg.configFile."karabiner/karabiner.json"` is not ideal for live reload,
even though it appears in Khanelinix. The implementation should manage the complete
directory or use a collision-safe activation copy, and it must not silently replace
an unmanaged existing directory. ([official configuration-path guidance](https://karabiner-elements.pqrs.org/docs/manual/misc/configuration-file-path/))

## One-time macOS approvals and operational caveats

The configuration is declarative, but Apple does not allow all security approvals
to be granted silently. First activation requires the user to allow Karabiner's
background services, Accessibility access, and Driver Extension. In Karabiner
16.0.0+, separate Input Monitoring permission is usually unnecessary because
Accessibility covers it. The virtual keyboard layout must match the physical
keyboard (ANSI/ISO/JIS). ([official installation guide](https://karabiner-elements.pqrs.org/docs/getting-started/installation/),
[required macOS settings](https://karabiner-elements.pqrs.org/docs/manual/misc/required-macos-settings/))

Karabiner captures physical keyboard events and forwards modified events through a
virtual keyboard. The project says processing remains local and it does not collect
keystrokes or configuration data. Its privileged architecture is documented, but
the required Accessibility and Driver Extension permissions are still powerful and
should be acknowledged during bootstrap. ([privacy](https://karabiner-elements.pqrs.org/docs/privacy/),
[security architecture](https://karabiner-elements.pqrs.org/docs/help/advanced-topics/security/))

Other caveats:

- Confirm the final rule in Karabiner-EventViewer before assigning many Raycast
  shortcuts.
- Do not create Karabiner mouse/scroll rules. SteerMouse already owns the MX mouse,
  so overlapping remappers risk double inversion or inconsistent device behavior.
- Do not disable an internal keyboard when an external keyboard connects; this is
  a desktop Mac and there is no benefit.
- Do not copy shell-command launchers from personal configurations. They embed app
  paths, expand the impact of a keyboard rule, and duplicate Raycast.
- Do not copy Vim navigation, Home/End rewrites, PC-style shortcuts, function-key
  changes, Command-Q guards, or per-device IDs without an explicit preference.
- A rule can later be narrowed using `device_if` after EventViewer identifies the
  actual keyboard. Universal behavior is simpler when every attached keyboard is
  intended to use Caps Lock as Hyper.
  ([official condition types](https://karabiner-elements.pqrs.org/docs/json/complex-modifications-manipulator-definition/conditions/),
  [typical device-specific example](https://karabiner-elements.pqrs.org/docs/json/typical-complex-modifications-examples/))

## Minimal acceptance checks after activation

1. Caps Lock held with a letter is observed as Control + Option + Command + Shift
   plus that letter.
2. Tapping Caps Lock alone sends Escape.
3. Left Shift alone and right Shift alone still capitalize normally.
4. Holding one Shift and pressing the other toggles real Caps Lock on and off.
5. A Raycast command bound to a four-modifier shortcut fires through the Karabiner
   Hyper key.
6. Raycast's native Hyper-key setting is disabled.
7. Hyper+I/J/K/L sends Up/Left/Down/Right.
8. Tapping Return sends Return; holding Return while pressing another key uses
   Control as the modifier.
9. The physical Escape key sends backtick/tilde, while tapped Caps Lock remains
   the available Escape key.
10. The Logitech keyboard's Fn+Escape mode toggle, function/media keys, and
    device-switch keys continue to work without Karabiner overrides.
11. SteerMouse scrolling and buttons are unchanged.
