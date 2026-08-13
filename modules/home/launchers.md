# Application launcher hotkeys

Home Manager disables only macOS symbolic hotkey 64, **Show Spotlight search**,
which releases Command–Space. Spotlight indexing and Finder's separate search
shortcut remain enabled. The activation deliberately updates one nested entry
instead of replacing the complete `AppleSymbolicHotKeys` dictionary.

Raycast owns the other half of the binding. In Raycast Settings → General, set
**Raycast Hotkey** to Command–Space. Raycast stores this setting in its encrypted
application database and provides no supported command-line or plain-preference
interface for it. Nix must not edit that database. Raycast's encrypted
`.rayconfig` export can transfer hotkeys, but it is mutable application data—not
public declarative configuration.

After a rebuild, verify Command–Space opens Raycast and that System Settings →
Keyboard → Keyboard Shortcuts → Spotlight shows **Show Spotlight search** off.
