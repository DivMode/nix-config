# Menu bar status items on macOS 15 Sequoia: Spotlight and Siri

Verified 2026-09-01 on macOS 15.7.7 (24G720), primarily by disassembling the
OS's own binaries rather than trusting blog recipes. Supports
`modules/home/menu-bar.nix`.

## Spotlight icon

- The magnifying-glass status item is owned and drawn by
  `/System/Library/CoreServices/Spotlight.app` — its binary holds the
  `NSStatusItem` ivar. Not SystemUIServer, not ControlCenter, on this OS.
- The authoritative preference is `MenuItemHidden` in `com.apple.Spotlight`,
  **ByHost**: Spotlight.app's own hide routine calls
  `CFPreferencesSetValue("MenuItemHidden", true, …, kCFPreferencesCurrentHost)`,
  and its show routine writes the same key back to false. Scripting the same
  key the OS itself writes is the whole argument for it.
- The similarly named `"NSStatusItem Visible Item-0"` records (in BOTH
  `com.apple.Spotlight` and `com.apple.controlcenter`) are AppKit's generic
  status-item autosave state, not the toggle. Sources that point at the
  controlcenter one are conflating domains that merely share AppKit's key
  naming.
- ByHost precedence is the classic trap: the ByHost domain shadows the plain
  one, so a plain `defaults write com.apple.Spotlight MenuItemHidden` appears
  to work only until a ByHost value exists. This is also why
  nix-darwin `system.defaults` cannot express it
  (https://github.com/nix-darwin/nix-darwin/issues/1721); Home Manager's
  `targets.darwin.currentHostDefaults` runs `defaults -currentHost import` as
  the user and is the faithful mechanism.
- `MenuItemHidden` gates only the status item's visibility. ⌘Space is a
  Keyboard Shortcuts setting, and indexing is mds — three separate things.
- Spotlight.app KVO-observes the key, so the icon likely updates on the write
  alone; `killall Spotlight` is the belt-and-braces refresh. Its LaunchAgent
  (`/System/Library/LaunchAgents/com.apple.Spotlight.plist`) is KeepAlive, so
  launchd respawns it immediately and ⌘Space keeps working. No logout needed.

## Siri icon

- Drawn by **SystemUIServer**, which loads
  `/System/Library/CoreServices/Siri.bundle`
  (`-[SUISStartupObject _loadSiri]`); the bundle binds
  `isStatusMenuVisible`/`setStatusMenuVisible:` to the `com.apple.Siri`
  domain. The `Siri` agent process (LaunchAgent `com.apple.Siri.agent`) is the
  Siri UX, not the icon; there is no `SiriAgent` process on 15.7.7 — advice to
  `killall SiriAgent` is obsolete.
- `StatusMenuVisible` (plain, non-ByHost) hides only the icon. Siri
  activation is governed elsewhere (`com.apple.assistant.support`,
  `"Assistant Enabled"`).
- `SiriPrefStashedStatusMenuVisible` sits beside it in the bundle; by name it
  is the state restored when Siri is re-enabled. That reading is a hypothesis
  (not runtime-tested); setting it to false alongside costs nothing.
- Refresh with `killall SystemUIServer` — KeepAlive, safe, no logout.

## Thaw (menu bar manager)

- Thaw 2.x requires macOS 26 ("The minimum deployment target is now macOS 26.
  Systems on macOS 14 or 15 stay on the 1.x line" —
  https://github.com/thaw-app/Thaw/releases/tag/2.0.0). Upstream homebrew-cask
  carries only 2.x (`depends_on macos: :tahoe`), so on Sequoia the newest
  installable release is 1.2.0 (2026-04-13), vendored in
  `taps/homebrew-pinned/Casks/thaw.rb`. The 1.x line looks frozen (a 1.3.0
  beta stalled 2026-04); it is a maintained fork of Ice and keeps Ice's
  defaults schema.
- Settings live flat in `com.stonerl.Thaw`; key names are defined in
  `Thaw/Utilities/Defaults.swift` (identical at 1.2.0 and on main):
  `AutoRehide`, `RehideStrategy`, `RehideInterval`, `EnableAlwaysHiddenSection`,
  `ShowOnClick`/`ShowOnHover`/`ShowOnScroll`, `HideApplicationMenus`,
  `NewItemsSection`. Behavioural switches can be pre-seeded declaratively.
- Per-item section membership persists in undocumented UserDefaults blobs
  (`MenuBarItemManager.savedSectionOrder` and friends) — technically seedable,
  practically fragile; leave item layout to the GUI (⌘-drag).
- The declarative-friendly surfaces Thaw advertises — JSON profiles under
  `~/Library/Application Support/Thaw/Profiles/` and an authorization-gated
  `thaw://` settings-write URI — are 2.x/Tahoe-only. On 1.2.0 only basic
  `thaw://` toggle deep links exist. No CLI on either line.
