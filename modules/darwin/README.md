# Darwin modules

These modules own macOS system configuration, Dock contents, fonts, Nix, and
native/vendor applications.

## Package ownership

`homebrew.nix` is the canonical Homebrew declaration. Native applications and
vendor-distributed macOS tools are casks. Portable command-line tools belong in
Home Manager unless a nearby comment documents a concrete nixpkgs gap.

Activation uses strict desired-state reconciliation:

```nix
homebrew.onActivation.cleanup = "uninstall";
```

Global `"zap"` is forbidden because it can delete application-associated user
data. Automatic Homebrew update and upgrade are disabled so a rebuild does not
silently change package versions. `claude-code` is Anthropic's terminal CLI; the
separate Claude desktop cask is intentionally absent.

## Dock and macOS defaults

`dock.nix` is the Dock source of truth. Finder is supplied implicitly by macOS;
the remaining declared applications are explicit. The Dock auto-hides, excludes
recent applications and persistent file/folder entries, and uses recent-use
Spaces arrangement.

`chrome-web-apps.nix` declares Google's real Gmail PWA through Chrome's supported
`WebAppInstallForceList` platform policy. Chrome—not Nix—creates the native
`~/Applications/Chrome Apps.localized/Gmail.app` shim after each profile first
processes the policy. The Dock pins that shim immediately after Chrome.

The system-wide policy applies to every local Chrome profile and makes Chrome
display **Managed by your organization**. Nix owns only the public install URL
and window behavior. Chrome still owns profile selection, sign-in, cookies,
history, Gmail sessions, and the derived app shim. On a new Mac, open or restart
Chrome after the first switch, verify `WebAppInstallForceList` in
`chrome://policy`, and reload the Dock after Gmail.app appears. Activation
refuses to overwrite a Chrome policy file it did not create or that changed
outside nix-config.

`macos-defaults.nix` owns a deliberately small Finder, keyboard-repeat,
save-panel, screenshot, widget, login-window, and scrolling baseline. Finder's
Column View does not guarantee a fixed number of visible columns.

Screenshots are stored in the writable `~/Documents/Screenshots` directory
created collision-safely by Home Manager. Tap-to-click and battery percentage
are intentionally unset for the desktop baseline.

`spotlight.nix` installs a launch daemon that runs at load and whenever a volume
mounts. It asks `diskutil` whether each mounted volume is internal and reconciles
Spotlight indexing and searching off only when macOS reports `Internal = false`.
It never names drives or applies `mdutil -a`. Classification and reconciliation
failures are logged, retried three times, and returned as service failures. Apple
does not allow Time Machine's required backup indexing to be disabled.
