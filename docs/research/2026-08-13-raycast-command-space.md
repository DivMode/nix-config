# Raycast on Command-Space

Date: 2026-08-13

## Decision

Release **Command-Space** from Spotlight through nix-darwin, but assign it to
Raycast once through Raycast's supported Settings UI. Do not write Raycast's
encrypted database or depend on its old private `raycastGlobalHotkey` defaults
key.

This preserves the intended ownership boundary:

- Nix owns the macOS shortcut conflict.
- Raycast owns its own launcher shortcut.
- Spotlight indexing remains enabled; only its launcher shortcut is disabled.

Raycast itself recommends this exact user-facing setup: uncheck **Show Spotlight
search** under System Settings → Keyboard → Keyboard Shortcuts → Spotlight, then
record Command-Space as the **Raycast Hotkey** in Raycast Settings → General.
Raycast also warns that Input Sources may own the same shortcut on systems that
use or previously used multiple keyboard layouts. ([Raycast Settings manual](https://manual.raycast.com/settings))
Apple documents Command-Space as Spotlight's standard shortcut. ([Apple Spotlight
shortcuts](https://support.apple.com/en-lamr/guide/mac-help/mh26783/mac), [Apple Mac
keyboard shortcuts](https://support.apple.com/en-us/102650))

## macOS implementation

### Backing preference

Spotlight search is represented in the private
`com.apple.symbolichotkeys` preference domain by `AppleSymbolicHotKeys` entry
`64`. Apple does not publish the numeric IDs or the plist schema as a supported
API, so the ID and encoding are implementation evidence, not an Apple contract.

Common full representations of Command-Space use symbolic-hotkey ID `64`, type
`standard`, hardware key code `49` for Space, and Command modifier mask
`1048576`. Existing configurations vary in the first parameter (`32` for the
Space character or the legacy `65535` sentinel). The full key encoding is not
needed to disable the shortcut: the minimal entry is simply:

```plist
<dict>
  <key>enabled</key>
  <false/>
</dict>
```

### No typed nix-darwin option

The repository pins nix-darwin revision
`c3e90c89649b07d1a96e4b9dd6cd0d6e44b91a74`. That revision has no typed option
for symbolic hotkeys. It only exposes free-form
`system.defaults.CustomUserPreferences`. ([nix-darwin custom preferences
module](https://github.com/nix-darwin/nix-darwin/blob/c3e90c89649b07d1a96e4b9dd6cd0d6e44b91a74/modules/system/defaults/CustomPreferences.nix))

Do **not** express only entry `64` as this:

```nix
system.defaults.CustomUserPreferences."com.apple.symbolichotkeys" = {
  AppleSymbolicHotKeys."64".enabled = false;
};
```

nix-darwin's defaults writer serializes the supplied value and writes the
entire top-level `AppleSymbolicHotKeys` key. Supplying only entry `64` can
replace the dictionary and remove unrelated keyboard-shortcut entries.
([nix-darwin defaults writer](https://github.com/nix-darwin/nix-darwin/blob/c3e90c89649b07d1a96e4b9dd6cd0d6e44b91a74/modules/system/defaults-write.nix))
The live Mac has other symbolic-hotkey entries, so preserving siblings is not
theoretical.

The safe Nix-owned convergence is a narrowly scoped activation step, executed
as the primary user, which merges only ID `64`:

```sh
/usr/bin/defaults write com.apple.symbolichotkeys \
  AppleSymbolicHotKeys -dict-add 64 \
  '<dict><key>enabled</key><false/></dict>'
```

This is still declarative in the practical sense: every `darwin-rebuild switch`
converges the one owned entry without assuming ownership of the entire shortcut
dictionary. It is not a supported Apple API. A logout/login is the supported
way to ensure all processes reload keyboard preferences; invoking Apple's
private `activateSettings` helper is common implementation evidence but should
not be presented as a public contract.

Current repository evidence supports the surgical merge. The actively
maintained [lovesegfault/nix-config](https://github.com/lovesegfault/nix-config/blob/43c6688f9ff9c1ba3daa898cec55754c34bdb415/modules/darwin/graphical/default.nix#L142-L151)
uses `-dict-add 64` specifically to preserve the rest of the dictionary. Other
popular Nix configurations show the concise free-form approach, including
[rgomezcasas/dotfiles](https://github.com/rgomezcasas/dotfiles/blob/8849dbacc2e7610764778a4144e1c1a7f6a31bba/config/nix/system/macos-defaults.nix#L148-L151),
but that approach inherits nix-darwin's whole-key replacement behavior.

## Raycast implementation

### Supported path

After the Spotlight shortcut is released:

1. Open Raycast Settings → General.
2. Select **Raycast Hotkey**.
3. Record Command-Space.
4. If it is rejected, also inspect System Settings → Keyboard → Keyboard
   Shortcuts → Input Sources for a conflict.

Raycast says the setting applies through its recorder and does not document a
relaunch requirement. No extra Accessibility permission is documented merely
for registering this global shortcut. ([Raycast Settings manual](https://manual.raycast.com/settings))

### Why Nix should not write the Raycast hotkey

Raycast does not expose the launcher hotkey through a documented CLI, extension
API, declarative schema, or single-setting import API. The installed Raycast
1.104.24 build recognizes historical strings associated with
`raycastGlobalHotkey`, and older/public dotfiles commonly write
`"Command-49"`, but the live preference domain does not contain that setting.
Current Raycast state is held in its encrypted application database. Writing
the historical defaults key is therefore an unsupported private-data hack with
no stable convergence guarantee.

Raycast's official portable mechanism is an encrypted `.rayconfig` export and
import. It includes **Settings, Aliases & Hotkeys**, but it is an interactive,
whole-configuration transfer—not a documented headless API for one preference.
Imports merge data and may prompt about hotkey transfer/conflicts. ([Raycast
Import & Export manual](https://manual.raycast.com/import-export))

Raycast Pro Cloud Sync also syncs hotkeys. If enabled, it should remain the sole
owner of Raycast's hotkey state; repeatedly forcing a private local value from
Nix could race or conflict with synced state. ([Raycast Pro and Cloud Sync](https://www.raycast.com/changelog/macos/1-51-0))

## Activation and verification

Safe activation ownership is:

1. Nix merges only `AppleSymbolicHotKeys[64].enabled = false` as the primary
   user.
2. The user records Command-Space in Raycast once.
3. Raycast or its Cloud Sync owns the Raycast-side value thereafter.

Verify after activation:

- `defaults read com.apple.symbolichotkeys AppleSymbolicHotKeys` shows entry
  `64` disabled and retains all sibling entries.
- Command-Space opens Raycast, not Spotlight.
- Option-Command-Space retains Finder search unless separately changed.
- Spotlight file indexing remains enabled; this change does not invoke
  `mdutil` and does not affect search data.

For a strict zero-UI rebuild, a supported Raycast-side interface does not
currently exist. A functional alternative is to keep Raycast's default
Option-Space shortcut and declaratively remap Command-Space to Option-Space in
Karabiner after releasing Spotlight. That is reproducible, but it is a keyboard
remap rather than changing Raycast's own stored preference, and Option-Space
would continue to work too.
