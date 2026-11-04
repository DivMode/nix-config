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

A `pkg` cask — `karabiner-elements`, `adobe-acrobat-pro` — is
installed by handing its payload to `/usr/sbin/installer` as root, and removed
or upgraded through the vendor's own scripts, `launchctl`, `pkgutil`, and `rm`,
all as root and all with sudo's `-E`. Activation cannot answer for any of that
from a shell with no terminal. `homebrew.nix` supplies
`onActivation.extraEnv.SUDO_ASKPASS` so Homebrew passes sudo's `-A`, and
`sudo.nix` declares a `NOPASSWD:SETENV: ALL` entry so no dialog is drawn. Both
are needed: without the first, activation aborts mid-switch with *a terminal is
required to read the password*; without the second it stops on a prompt. The
entry is deliberately not a list of binaries — the earlier one, which named
`installer` and `pkgutil` without SETENV, refused Homebrew's `-E` outright and
broke a Karabiner upgrade half-way on 2026-09-06; `sudo.nix` carries the
evidence. `askpass.nix` owns the single askpass helper both consumers share.

Anthropic's Claude Code terminal CLI is **not** a cask here. It is Anthropic's
self-updating native install behind a Nix launcher
(`modules/home/development.nix`), because the cask lags the upstream release
stream by days. The separate Claude desktop cask is intentionally
absent.

## Agent hooks

`agent-hooks.nix` installs machine-managed hooks for Claude Code and Codex.
`ai/hooks/default.nix` is the single declaration of every handler, its kind,
event, matcher, command, and explicit timeout (at most 15 seconds). Repositories
cannot add agent hooks: Claude's `allowManagedHooksOnly` and Codex's
`allow_managed_hooks_only` skip unmanaged hook sources, including session hooks.
No plugins are force-enabled through managed Claude settings.

Claude still accepts Agent SDK hooks registered in-process. Using that residual
requires a program that embeds Claude, which is reviewed as code; editing
configuration cannot register an SDK hook. Under managed-only mode, Claude's
`/goal` cannot run and plugin hooks stop unless the plugin is force-enabled in
managed `enabledPlugins`. None are force-enabled here.

An `observe` handler never blocks. A `deny` handler is allowed only on
PreToolUse and may refuse a specific forbidden command only through
`permissionDecision: "deny"` JSON with exit 0. Stop, SubagentStop, PreCompact,
and UserPromptSubmit handlers are forbidden because they can force or stall
model turns. Broken input or a handler's own failure must never become a denial.

Every managed command runs through the pinned-Python supervisor. It passes
stdin to the handler, kills its process group before the client timeout, and
always exits 0, including on its own errors. Observers emit no stdout; deny
handlers can emit only a validated PreToolUse permission denial after a
successful exit. All other stdout is discarded, and stderr is limited to one
short line. The contract executes these exact supervised commands. Fixtures
cover exit-2 failures, hangs, observer blocking output, and non-deny controls;
the raw exit-2 fixture still proves the build gate catches an unsupervised hook.

Both managed files are outputs of the hook-contract derivation. Before writing
them, it runs each real command with malformed, empty, null, and harmless event
payloads under `env -i`, a bare PATH and no HOME tools. It checks exit
status, output controls, and deliberate guard denials; separate flake checks
prove rejection of an exit-2 hook and a Stop declaration, including the
expected failure reason.

Claude's validated JSON is installed atomically at
`/Library/Application Support/ClaudeCode/managed-settings.json`, owned by
root:wheel, mode 0644, in a mode-0755 directory. A receipt prevents overwriting
an unmanaged or externally changed policy. If installation stops after the
policy rename, the expected policy bytes permit repairing its stale or missing
receipt; bytes matching neither the receipt nor the desired policy are refused.
No launchd reconciler is needed:
macOS preserves this directory at boot. The ccstatusline `statusLine` lives
there too because managed-only mode ignores a user status line. Home Manager
removes the old `hooks` and `statusLine` keys from the live user settings.

Codex's `/etc/codex/requirements.toml` is owned by nix-darwin's
`environment.etc`. Its PreToolUse guard is inert unless a delegation launch
sets `CODEX_ORCHESTRATOR_DELEGATED=1`; both dispatch and resume do so. Ordinary
owner sessions can commit. Delegation supplies no inline hook or trust bypass.
`[features] hooks = true` is pinned in the requirements file so local feature
configuration cannot disable the managed guard. Codex's legacy `notify`
command runs outside managed hooks; it is fire-and-forget and cannot block or
continue a turn.

## Dock and macOS defaults

`dock.nix` is the Dock source of truth. Finder is supplied implicitly by macOS;
the remaining declared applications are explicit. The Dock auto-hides, excludes
recent applications, and uses recent-use Spaces arrangement. Its one
`persistent-others` entry is the downloads directory from `local.nix`, declared
in attrset form so the stack sorts by `date-modified` rather than the
alphabetical default. The tile shows a question mark whenever that path is an
unmounted share. It also shows one after a share is remounted: the bookmark the
Dock stored for the old volume stops resolving, and the Dock trusts it over the
path. `dock.py` treats a bookmark that no longer resolves to its own path as
stale and drops it, both on activation and, via `dock.py --refresh-stale`, on
every `mount-network-shares` pass.

`chrome.nix` is the single Chrome policy file. It declares Google's real Gmail
PWA through Chrome's supported `WebAppInstallForceList` platform policy, and
the Loom screen-recorder extension through `ExtensionInstallForcelist`.
Chrome—not Nix—creates the native `~/Applications/Chrome Apps.localized/Gmail.app`
shim after each profile first processes the policy, and the Dock pins it right
after Chrome. The policy's `custom_icon` gives the shim the Gmail icon even
before the profile is signed in; after signing in, quit and reopen Chrome once.

That generated policy file carries only keys that are mandatory-only upstream,
and the receipt guard and reconciler daemon around it exist only for those.
`WebAppInstallForceList` is `RECOMMENDED_PROHIBITED` and
`ExtensionInstallForcelist` has no recommended form, so Chrome accepts both
only as forced values, and without MDM the only source of forced values is
`/Library/Managed Preferences` — the directory macOS rebuilds at every boot. The
daemon therefore runs on an interval rather than only at load. Running at load
is not enough: a one-shot cannot repair a wipe that happens after it exits, and
on 2026-08-31 that is exactly what happened — the daemon ran, took its
"hash matches, nothing to do" exit, and macOS rebuilt the directory afterwards.

A force-installed extension lands in every profile, cannot be disabled from
`chrome://extensions`, and — per the policy's own definition — is uninstalled
by Chrome as soon as it leaves the list. Signing in to the extension is still
per-profile state.

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
Chrome after the first switch, verify `WebAppInstallForceList` and
`ExtensionInstallForcelist` in `chrome://policy`, and reload the Dock after
Gmail.app appears. Activation
refuses to overwrite a Chrome policy file it did not create or that changed
outside nix-config.

`macos-defaults.nix` owns a deliberately small Finder, keyboard-repeat,
save-panel, screenshot, widget, login-window, and scrolling baseline. Finder's
Column View does not guarantee a fixed number of visible columns.

Screenshots are stored in the writable `~/Documents/Screenshots` directory
created collision-safely by Home Manager. Tap-to-click and battery percentage
are intentionally unset for the desktop baseline.

`fseventsd-guard.nix` works around a macOS 27.0/27.0.1 bug (FB25046068): after
heavy file churn, fseventsd pins a core for days and its heap grows without
bound (70 GB here on 2026-11-02, until swap ran out). A root launch daemon
samples its footprint and CPU share every minute into
`/var/db/fseventsd-guard/samples.log`. Past 512 MB, or after 10 minutes above 80%
of a core, it saves stacks, heap, ports and log to `/var/log/fseventsd-guard/`
(at most hourly, 30 kept). Past 2 GB it saves evidence and restarts the daemon
with TERM, then KILL (`kickstart -k` is refused under SIP), at most 12 times a
day. FSEvents clients that were running at the restart stop receiving events
until their process restarts.

`spotlight.nix` installs a launch daemon that runs at load and whenever a volume
mounts. It asks `diskutil` whether each mounted volume is internal and reconciles
Spotlight indexing and searching off only when macOS reports `Internal = false`.
It never names drives or applies `mdutil -a`. Classification and reconciliation
failures are logged, retried three times, and returned as service failures. Apple
does not allow Time Machine's required backup indexing to be disabled.
