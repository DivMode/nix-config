# macOS defaults and SteerMouse configuration
**Date:** 2026-08-12
**Scope:** Research record supporting the staged declarative configuration. It did
not install or activate that configuration.
## Decisions

1. Declare supported macOS preferences with `nix-darwin` under `system.defaults`.
2. Use Finder **Column View** with `FXPreferredViewStyle = "clmv"`. This sets the preferred/default view; it does not guarantee a literal fixed count of three visible columns. Finder shows as many path and preview columns as the window and selection require, and individual folders can retain their own view state.
3. Use `InitialKeyRepeat = 15`, `KeyRepeat = 2`, and `ApplePressAndHoldEnabled = false`. This is fast, matches Wimpy and several current configurations, and is less aggressive than the unofficial 10/1 combination.
4. Keep macOS natural scrolling enabled for the trackpad. Configure reverse/standard wheel direction inside SteerMouse for the Logitech MX mouse. macOS exposes one global `com.apple.swipescrolldirection` value, not a supported independent mouse-versus-trackpad default.
5. Capture SteerMouse settings using its supported `Device.smsetting` export/copy mechanism. Restore a regular writable file during an explicit bootstrap step, not a permanent Nix-store symlink.
6. Leave internal Spotlight indexing unchanged and reconcile it off for external
   volumes, where terminal-native Git and file search do not need Spotlight. If
   Raycast is the launcher, optionally reclaim
   Command-Space and hide or reduce Spotlight suggestions; those are separate
   from the per-volume metadata-index policy.
7. Do not install Logi Options/Options+ alongside SteerMouse unless a specific MX hardware feature cannot work without it. Two utilities attempting to own the same buttons, scrolling, or wheel mode creates ambiguous state.

## What belongs where

| State | Declarative owner | Why |
| --- | --- | --- |
| Finder, keyboard, Dock, trackpad and supported Apple defaults | nix-darwin `system.defaults` | Typed, documented options with normal Darwin activation behavior |
| Apple preferences not represented by a typed option | `system.defaults.CustomUserPreferences` | Still declarative, but less stable; document the macOS version and risk |
| Text configuration such as TOML, JSON or shell files | Home Manager | Human-readable and merge/review friendly |
| SteerMouse opaque device state | Vendor export plus controlled bootstrap copy | The vendor documents a settings file and a restore procedure; the application needs writable runtime state |
| SteerMouse license | 1Password plus manual registration | Keep the public repository secret-free; SteerMouse has no documented CLI activation interface |
| Accessibility/Input Monitoring approvals | Manual macOS approval | These privacy controls intentionally require user consent |

## Requested settings

### Finder column view

The exact nix-darwin setting is:

```nix
system.defaults.finder.FXPreferredViewStyle = "clmv";
```

nix-darwin maps `clmv` to Column View. Apple describes Column View as a hierarchy of columns and a possible preview column; neither Apple nor nix-darwin provides an option for an invariant **three-column count**. Apple also says folder-specific settings persist, and Column View does not offer the same “Use as Defaults” control as other views. Therefore `clmv` is the right declarative preference, but “every existing folder always shows exactly three columns” is not a supported guarantee. ([nix-darwin Finder source](https://github.com/nix-darwin/nix-darwin/blob/nix-darwin-26.05/modules/system/defaults/finder.nix#L48-L56), [Apple Finder view guide](https://support.apple.com/en-gb/guide/mac-help/mchldaafb302/mac))

Useful companion settings:

```nix
system.defaults.finder = {
  FXPreferredViewStyle = "clmv";
  AppleShowAllExtensions = true;
  ShowPathbar = true;
  ShowStatusBar = true;
  _FXEnableColumnAutoSizing = true;
  _FXSortFoldersFirst = true;
  FXDefaultSearchScope = "SCcf";
  NewWindowTarget = "Home";
};
```

`SCcf` makes Finder search the current folder by default; it does not replace Spotlight's index. Each option above is present in the pinned nix-darwin 26.05 Finder module. ([source](https://github.com/nix-darwin/nix-darwin/blob/nix-darwin-26.05/modules/system/defaults/finder.nix))

### Fast key repeat

Recommended baseline:

```nix
system.defaults.NSGlobalDomain = {
  ApplePressAndHoldEnabled = false;
  InitialKeyRepeat = 15;
  KeyRepeat = 2;
};
```

`InitialKeyRepeat` is the delay before repeating begins; `KeyRepeat` is the interval once it begins. nix-darwin accepts signed integers but does not document or validate a supported numeric range. Values such as 10/1 are unofficially more aggressive. The 15/2 choice appears in Wimpy, Dustin Lyons, enocla, and another recent nix-darwin configuration; yurrriq uses 10/1. Disabling press-and-hold trades the accented-character popup for conventional repeating keys. ([nix-darwin option source](https://github.com/nix-darwin/nix-darwin/blob/nix-darwin-26.05/modules/system/defaults/NSGlobalDomain.nix), [Wimpy](https://github.com/wimpysworld/nix-config/blob/97efaed821fcbae491b33231ec62753c127b44c3/darwin/default.nix#L111-L216), [Dustin Lyons](https://github.com/dustinlyons/nixos-config/blob/c245c05fefb77f011b636fc0367c7be117658136/hosts/darwin/default.nix#L49-L85), [enocla](https://github.com/enocla/nix-config/blob/2e580c3bd68406edb5ce5fb8e74bf9a10d12a811/modules/darwin/preferences/keyboard.nix#L1-L8), [yurrriq](https://github.com/yurrriq/dotfiles/blob/d6e1c1b2809a56db138265b70f1dcb9af68006a5/modules/darwin.nix#L63-L90))

### Separate trackpad and MX mouse scrolling

The typed nix-darwin option is global:

```nix
system.defaults.NSGlobalDomain."com.apple.swipescrolldirection" = true;
```

It means “Natural” scrolling and does not distinguish device classes. Leave it `true` for the trackpad, then configure the MX wheel direction per mouse in SteerMouse. Do not also globally reverse macOS scrolling or the two layers can double-invert the wheel. ([nix-darwin option source](https://github.com/nix-darwin/nix-darwin/blob/nix-darwin-26.05/modules/system/defaults/NSGlobalDomain.nix), [SteerMouse product page](https://plentycom.jp/en/steermouse/index.html))

SteerMouse supports USB and Bluetooth mice, per-mouse configuration, and many Logitech MX models. Its release history explicitly lists MX Master, MX Master 3/3S, MX Anywhere models, and fixes for MX wheel-mode behavior. Exact support can still depend on the specific model and special buttons; the vendor says it has no exhaustive compatibility list. ([SteerMouse releases](https://plentycom.jp/en/steermouse/download.php), [SteerMouse FAQ](https://plentycom.jp/inc/faq.php?style=e&type=sm))

Use SteerMouse—not Logi Options+—as the owner of ordinary pointer, button, scroll-direction and wheel settings. If an MX-specific hardware feature later requires Logitech software, test that exception explicitly rather than installing both controllers by default.

## Making SteerMouse settings reproducible

SteerMouse's official settings file is:

```text
~/Library/Application Support/SteerMouse & CursorSense/Device.smsetting
```

The vendor's restore sequence is:

1. Quit SteerMouse.
2. Replace `Device.smsetting` with the saved file.
3. Open SteerMouse and click **Reconfigure** on the Device tab.

SteerMouse also documents export/import support for mouse and application settings. ([official FAQ](https://plentycom.jp/inc/faq.php?style=e&type=sm), [release notes](https://plentycom.jp/en/steermouse/download.php))

Recommended public-repository workflow:

1. Install and register SteerMouse, connect the exact MX mouse, and configure reverse wheel direction, buttons, pointer acceleration/sensitivity, wheel mode, and any per-app mappings.
2. Quit SteerMouse and copy the generated `Device.smsetting` into a reviewed repository asset.
3. Before committing, inspect and scan it for the license ID/code, personal paths, serials and other identifiers. The vendor does not document the file format or promise that registration data is absent.
4. Record its checksum and the SteerMouse/MX model used to create it.
5. Provide an explicit `restore-steermouse` bootstrap action that refuses to overwrite a different existing file unless the user requests replacement. It should copy—not symlink—the asset, because SteerMouse owns and mutates its runtime state.
6. Reopen SteerMouse and perform the vendor's **Reconfigure** step. Keep license entry and macOS privacy approvals manual.

This is reproducible state, not an ad hoc backup: the repository holds the desired non-secret profile, while the rebuild procedure materializes a writable vendor-owned copy. Because the format is opaque and may be device/version-specific, it should be treated as a versioned artifact rather than hand-generated Nix data.

## Spotlight

### Recommendation

Do **not** disable Spotlight for the entire Mac. The repository leaves internal
volumes unchanged and reconciles external volumes off. Users may independently
choose to keep internal indexing enabled for Finder and application metadata,
even if Raycast owns Command-Space.

Spotlight powers local metadata queries; Finder search exposes Spotlight-style metadata criteria, and third-party/macOS applications can query the same metadata framework. Apple warns that excluding the entire internal disk can suppress some application update notifications, and Time Machine backup-disk indexing cannot be turned off because it is necessary for Time Machine. ([Apple Spotlight framework](https://developer.apple.com/documentation/foundation/spotlight), [Apple Finder search](https://support.apple.com/en-ie/guide/mac-help/mh15155/mac), [Apple search privacy](https://support.apple.com/guide/mac-help/prevent-spotlight-searches-specific-folders-mchl1bb43b84/26/mac/26))

Instead, separate three decisions:

- **Indexing:** leave internal volumes unchanged; reconcile it off for external volumes.
- **Launcher shortcut:** assign Command-Space to Raycast if desired.
- **Suggestions/privacy:** disable unwanted result categories, related content, clipboard search, and “Help Apple Improve Search” in System Settings. Apple supports category-level control without destroying the local index. ([Apple Spotlight settings](https://support.apple.com/en-gb/guide/mac-help/mchl54d95e8a/mac), [Apple result categories](https://support.apple.com/en-ie/guide/mac-help/mchl3e00eae9/mac))

The reviewed Nix repositories overwhelmingly retain indexing. Some hide the Spotlight menu item or move its shortcut; a rare configuration invokes `mdutil` during activation, but that is an imperative exception rather than a nix-darwin typed default.

The adopted implementation leaves internal volumes unchanged. A declarative
launch daemon classifies each mounted volume and reconciles indexing and search
off only when macOS reports that volume as external. This supersedes the earlier
manual per-volume proposal while retaining its no-blanket-command boundary.

## Conservative candidate defaults

### Essential

```nix
system.defaults = {
  NSGlobalDomain = {
    ApplePressAndHoldEnabled = false;
    InitialKeyRepeat = 15;
    KeyRepeat = 2;
    "com.apple.swipescrolldirection" = true;
  };

  finder = {
    FXPreferredViewStyle = "clmv";
    AppleShowAllExtensions = true;
    ShowPathbar = true;
    ShowStatusBar = true;
    _FXEnableColumnAutoSizing = true;
    _FXSortFoldersFirst = true;
    FXDefaultSearchScope = "SCcf";
    NewWindowTarget = "Home";
  };
};
```

Further typed options worth deciding explicitly are tap-to-click, full keyboard access,
expanded save panels, battery percentage, guest login, Dock autohide, Dock recents,
Space reordering, screenshots and desktop widgets. Avoid undocumented preference
keys, destructive cleanup, Gatekeeper weakening, automated TCC database changes,
full Spotlight shutdown, and concurrent SteerMouse/Logi Options+ ownership.

## Repository survey

Six current macOS Nix configurations were inspected:

| Repository | Relevant pattern |
| --- | --- |
| [wimpysworld/nix-config](https://github.com/wimpysworld/nix-config/blob/97efaed821fcbae491b33231ec62753c127b44c3/darwin/default.nix#L111-L216) | 15/2 repeat; Finder list view; extensions, hidden files, path and status bars; `CustomUserPreferences` for unsupported domains |
| [dustinlyons/nixos-config](https://github.com/dustinlyons/nixos-config/blob/c245c05fefb77f011b636fc0367c7be117658136/hosts/darwin/default.nix#L49-L85) | 15/2 repeat, press-and-hold disabled, trackpad/Dock defaults; no forced Finder view |
| [bgub/nix-macos-starter](https://github.com/bgub/nix-macos-starter/blob/be8f6df68c5cdeacc6e7f4d8a37b1c785b0fb9f5/darwin/settings.nix#L13-L33) | Small supported Finder/typing/window set; no forced Finder view or repeat |
| [enocla/nix-config](https://github.com/enocla/nix-config/blob/2e580c3bd68406edb5ce5fb8e74bf9a10d12a811/modules/darwin/preferences/finder.nix#L1-L10) | Preferences split into small modules; 15/2 repeat; natural scroll retained |
| [yurrriq/dotfiles](https://github.com/yurrriq/dotfiles/blob/d6e1c1b2809a56db138265b70f1dcb9af68006a5/modules/darwin.nix#L63-L90) | Aggressive 10/1 repeat and full keyboard access |
| [mrkuz/macos-config](https://github.com/mrkuz/macos-config/blob/9f22817a23906613908c2ca0ea1a3b7db2c1e9d9/hosts/darwin/m4/docs/system-settings.md#L23-L45) | Keeps unsupported/current UI choices in a manual checklist, including Spotlight privacy/menu preferences |

There is no universal “best macOS settings” list. The repeat rate, Finder information bars, extensions, Dock cleanup, and trackpad click settings recur; Finder view, natural scrolling, text correction, appearance, and window behavior vary substantially. The defensible best practice is a small reviewed baseline plus explicit user choices—not bulk importing hundreds of old `defaults write` commands.

No preference, application, license, privacy approval, or index state was changed while producing this report.
