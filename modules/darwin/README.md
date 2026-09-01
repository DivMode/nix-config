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
data. `onActivation.autoUpdate` stays disabled so activation never contacts
Homebrew's remotes; the taps are pinned flake inputs, so there is nothing to
fetch. `onActivation.upgrade` is enabled, which brings an installed cask to the
version the pinned tap defines — still governed by `flake.lock`, so a version
change remains a reviewable diff rather than something a rebuild does silently.

Most declared casks carry Homebrew's `auto_updates` flag and update themselves,
which is why `onActivation.upgrade` is what keeps `1password-cli` — the one cask
with no self-updater — current. Two casks are declared with an explicit `greedy`
value because that default is wrong for them:

- `karabiner-elements` is `greedy = true`. `brew upgrade` skips any cask marked
  `auto_updates`, so `upgrade` alone never touched it and it sat at 16.1.0
  against a pinned tap defining 16.2.0. Greedy cannot pull arbitrary versions:
  the tap is a flake input, so it can only reach the version `flake.lock` names.
- `adobe-acrobat-pro` is `greedy = false`, stated rather than defaulted so the
  intent survives a later `homebrew.greedyCasks = true`. The cask is unversioned
  (`sha256 :no_check`, downloaded from Adobe), so greedy would re-fetch about a
  gigabyte on every activation.

Acrobat is the one application here whose version is not to change without its
owner saying so, and Homebrew is only one of the three things that could change
it. `adobe-updates.nix` closes the other two: Adobe's ARM launchd updater, which
otherwise runs at every login and every 3.5 hours, and the in-app
**Help > Check for Updates**, which never touches launchd. Neither half covers
the other's gap, so both are declared.

A `pkg` cask — `karabiner-elements`, `adobe-acrobat-pro`, `logi-options+` — is
installed by handing its payload to `/usr/sbin/installer` as root, which
activation cannot do from a shell with no terminal. `homebrew.nix` supplies
`onActivation.extraEnv.SUDO_ASKPASS` so Homebrew passes sudo's `-A`, and
`sudo.nix` declares a NOPASSWD rule for `/usr/sbin/installer` and
`/usr/sbin/pkgutil` so the dialog is never drawn. Both are needed: without the
first, activation aborts mid-switch with *a terminal is required to read the
password*; without the second it stops on a prompt. `askpass.nix` owns the
single askpass helper both consumers share.

Anthropic's Claude Code terminal CLI is **not** a cask here. It is a Nix
package from the `llm-agents` flake input, because the cask lags the upstream
release stream by days. The separate Claude desktop cask is intentionally
absent.

## Dock and macOS defaults

`dock.nix` is the Dock source of truth. Finder is supplied implicitly by macOS;
the remaining declared applications are explicit. The Dock auto-hides, excludes
recent applications, and uses recent-use Spaces arrangement. Its one
`persistent-others` entry is the downloads directory from `local.nix`, declared
in attrset form so the stack sorts by `date-modified` rather than the
alphabetical default. The tile shows a question mark whenever that path is an
unmounted share; the stack renders the path it was given.

`chrome.nix` is the single Chrome policy file. It declares Google's real Gmail
PWA through Chrome's supported `WebAppInstallForceList` platform policy.
Chrome—not Nix—creates the native `~/Applications/Chrome Apps.localized/Gmail.app`
shim after each profile first processes the policy. The Dock pins that shim
immediately after Chrome.

That generated policy file carries exactly one key, and the receipt guard and
reconciler daemon around it exist only for that key.
`WebAppInstallForceList` is `RECOMMENDED_PROHIBITED` upstream, so Chrome accepts
it only as a forced value, and without MDM the only source of forced values is
`/Library/Managed Preferences` — the directory macOS rebuilds at every boot. The
daemon therefore runs on an interval rather than only at load. Running at load
is not enough: a one-shot cannot repair a wipe that happens after it exits, and
on 2026-08-31 that is exactly what happened — the daemon ran, took its
"hash matches, nothing to do" exit, and macOS rebuilt the directory afterwards.

Downloads are **not** in that file. `DownloadDirectory` and
`PromptForDownloadLocation` are ordinary user preferences written to
`com.google.Chrome`, which Chrome still reads as policy at *recommended* level;
nothing wipes a user preference, so downloads no longer depend on the managed
file being present. The recommended-form `DefaultDownloadDirectory` is still not
used — `DownloadDirectory` overrides it and it cannot be mandatory anywhere. The
cost of recommended level is that a value already set in Chrome's own settings
shadows the declared one, so changing the directory in `local.nix` does not move
a profile carrying its own `download.default_directory`.

Note the precondition — **the share is not mounted declaratively by this
repository.** If the downloads path is not mounted when Chrome starts a
download, the path is not there to write to. See the Chrome section of
`docs/state-boundary.md`.

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
