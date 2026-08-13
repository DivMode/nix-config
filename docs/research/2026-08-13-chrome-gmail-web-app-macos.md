# Declarative Gmail Chrome web app on macOS

Research date: 2026-08-13

## Conclusion

A real Gmail Chrome web app can be requested declaratively on macOS, but it
cannot be built or copied into place by Nix itself. The correct ownership split
is:

1. nix-darwin/Homebrew installs Google Chrome.
2. Nix owns Chrome's mandatory `WebAppInstallForceList` platform policy.
3. Chrome processes that policy in each Chrome profile and creates the native
   macOS app shim.
4. nix-darwin owns the Dock order and points at the shim Chrome creates.

Chrome's policy supports silent web-app installation on macOS from version 75.
The list item needs a URL and can request a separate window; leaving
`install_as_shortcut` unset installs the PWA normally rather than creating a
plain website shortcut. `create_desktop_shortcut` is only meaningful on Linux
and Windows and has no effect on Mac. ([Chrome Enterprise policy
reference](https://chromeenterprise.google/policies/web-app-install-force-list/),
[Mac deployment guide](https://support.google.com/chrome/a/answer/9367354?hl=en))

Google publishes a dedicated, first-party install endpoint for Gmail and
recommends it for reliable administrative installation:

```text
https://mail.google.com/mail/installwebapp?usp=admin
```

([Google's web-app installation troubleshooting](https://support.google.com/chrome/a/answer/6177447?hl=en-EN))

The intended policy entry is therefore conceptually:

```nix
WebAppInstallForceList = [
  {
    url = "https://mail.google.com/mail/installwebapp?usp=admin";
    default_launch_container = "window";
    fallback_app_name = "Gmail";
    custom_name = "Gmail";
  }
];
```

`fallback_app_name` gives the placeholder a stable name if authentication is
required during installation; `custom_name` keeps the installed app's name
stable on current desktop Chrome. Neither supplies credentials. Signing in to a
Google account and Chrome's cookies remain mutable per-profile state.

## Why this is a real Chrome app, not a Nix wrapper

Chromium describes macOS app shims as thin helper applications created by
Chrome so web apps appear separately from Chrome. The shim locates the matching
Chrome version and user-data directory, connects to an existing Chrome process
or launches one, and then hosts the web-app window. ([Chromium app-shim
architecture](https://chromium.googlesource.com/chromium/src/+/lkgr/chrome/app_shim/README.md))

The app bundle normally lives at:

```text
~/Applications/Chrome Apps.localized/Gmail.app
```

Chromium's macOS shortcut documentation says Chrome-generated bundles generally
reside under `~/Applications/[Chrome|Chrome Canary|Chromium] Apps.localized/`.
The bundle contains `Info.plist`, a generic `app_mode_loader`, icons, and
localized resources. It may be renamed or moved by the user, which is another
reason Nix should treat it as Chrome-owned derived state rather than a Nix-store
artifact. ([Chromium macOS shortcut
documentation](https://chromium.googlesource.com/chromium/src/+/HEAD/chrome/browser/web_applications/os_integration/mac/README.md))

Current Chromium source identifies Gmail's manifest ID as
`https://mail.google.com/mail/?usp=installed_webapp` and the derived app ID as
`fmgjjmmmlfnkbppncabfkddbjimcfncm`. The install policy should use Google's
dedicated install URL rather than hard-coding this app ID; the ID is useful only
for diagnosis and bundle verification. ([Chromium app-ID
constants](https://chromium.googlesource.com/chromium/src/+/HEAD/ash/constants/web_app_id_constants.h))

For current Google Chrome, the usual bundle identifier is either:

```text
com.google.Chrome.app.fmgjjmmmlfnkbppncabfkddbjimcfncm
com.google.Chrome.app.<profile-directory>-fmgjjmmmlfnkbppncabfkddbjimcfncm
```

Chromium constructs a profile-agnostic identifier for a multi-profile shim and
adds the normalized profile directory when the shim is profile-specific. The
source also searches for both forms while migrating older shims. ([Chromium
macOS shortcut implementation](https://chromium.googlesource.com/chromium/src/+/lkgr/chrome/browser/web_applications/os_integration/mac/web_app_shortcut_mac.mm))

## Applying the policy on a personal Mac

Google's documented fleet path is a `com.google.Chrome` configuration profile.
The guide starts from a Chrome policy plist, converts it to a `.mobileconfig`,
and deploys it as managed configuration. ([Google's Mac policy
guide](https://support.google.com/chrome/a/answer/9020077?hl=en))

The browser does not need Chrome Enterprise cloud enrollment to consume a local
platform policy. Google says platform policies on Mac come from Managed
Preferences and are visible even when the user is not signed into a managed
account. Its cleanup documentation explicitly recognizes manually created
`/Library/Managed Preferences/com.google.Chrome.plist` and
`/Library/Preferences/com.google.Chrome.plist` files. ([policy source and scope](https://support.google.com/chrome/a/answer/9024365?hl=en),
[Google's macOS policy cleanup](https://support.google.com/chrome/a/answer/9844476?hl=en))

Chromium's platform-policy loader confirms the mechanism: it reads macOS
preferences for `com.google.Chrome`, tests whether each value is forced, and
maps forced values to mandatory platform policy. ([Chromium policy-loader
source](https://chromium.googlesource.com/chromium/src/+/main/components/policy/core/common/policy_loader_mac.mm))

Therefore the most defensible local implementation is for nix-darwin to
generate the complete `com.google.Chrome.plist` and install it at
`/Library/Managed Preferences/com.google.Chrome.plist` as a root-owned `0644`
file. This is a local machine policy, not MDM enrollment and not Google cloud
management. Chrome will nevertheless display **Managed by your organization**
because the machine is intentionally setting mandatory browser policy.

Do **not** rely solely on
`system.defaults.CustomUserPreferences."com.google.Chrome"` for this policy.
nix-darwin documents that option as ordinary custom user preferences, while
Chromium's policy definition does not declare `WebAppInstallForceList` as a
policy that can be merely recommended. A regular preference may consequently
appear in `chrome://policy` with an unsupported level instead of force-installing
the app. The mandatory managed-preference file matches Chrome's policy model.
([nix-darwin custom-preference options](https://nix-darwin.github.io/nix-darwin/manual/#opt-system.defaults.CustomUserPreferences),
[Chromium policy definition](https://chromium.googlesource.com/chromium/src/+/HEAD/components/policy/resources/templates/policy_definitions/Miscellaneous/WebAppInstallForceList.yaml))

The generated plist must be the source of truth for the entire Chrome managed
domain. An activation script must replace it atomically and remove it if Chrome
policies are disabled; appending keys imperatively would leave undeclared policy
behind. No Google account, email address, cookies, or profile display name
belongs in that plist.

## Dock ordering and first-rebuild behavior

nix-darwin's `system.defaults.dock.persistent-apps` is the appropriate source of
truth for ordered Dock applications. The Gmail path should immediately follow
Google Chrome:

```nix
system.defaults.dock.persistent-apps = [
  "/System/Applications/Launchpad.app"
  "/Applications/Google Chrome.app"
  "${local.homeDirectory}/Applications/Chrome Apps.localized/Gmail.app"
  "/Applications/ChatGPT.app"
  "/Applications/cmux.app"
];
```

The option accepts application paths and preserves list order. ([nix-darwin
Dock option](https://nix-darwin.github.io/nix-darwin/manual/#opt-system.defaults.dock.persistent-apps))

There is an unavoidable convergence boundary on a brand-new Mac:

- nix-darwin can install Chrome, write the policy, and declare the future Dock
  path in one switch;
- Chrome does not create `Gmail.app` until Chrome starts and a profile processes
  the policy;
- the Dock can show a question mark while that path does not exist; and
- after Chrome creates the shim, the Dock must reload (or a later switch must
  rewrite it) to resolve the item reliably.

The existing post-activation Dock reload only handles applications that exist by
the end of nix-darwin/Homebrew activation. It cannot guarantee that Chrome has
already processed its web-app policy. The implementation should therefore make
this timing explicit: first switch, launch/restart Chrome, verify the policy and
shim, then reload the Dock. It must not claim that the real PWA is a one-process
Nix build artifact.

A fully Nix-built `.app` wrapper that launches
`Google Chrome --app=https://mail.google.com` would exist early enough for a
single atomic Dock switch, but it would **not** be the Chrome-installed Gmail
PWA. It would bypass Chrome's manifest lifecycle, OS integration, app identity,
and multi-profile shim behavior. That is not the requested implementation.

### Assessment of the Nix-owned wrapper alternative

The repository's evaluated alternative—an ordinary Nix-built `Gmail.app` whose
executable runs Google's Chrome binary with `--app=<gmail-url>`—is not inherently
unsafe. It launches an HTTPS Google URL in the already-installed Chrome binary,
keeps authentication in Chrome, requires no stored credentials, and provides a
stable bundle path that the Dock can resolve during the same activation.

Its limitation is semantic, not primarily security-related: `--app` is a browser
launch mode. The wrapper does not tell Chrome to install the Gmail PWA, does not
create a web-app registry entry or Chrome app shim, and is not tied to Gmail's
manifest-derived app ID. Consequently it does not reproduce the result of
Chrome's **Install page as app** operation.

It is also profile-ambiguous. Without `--profile-directory`, Chrome decides
which existing profile handles the URL. Hard-coding `--profile-directory` would
make the behavior deterministic on the present Mac but would expose a local
profile-directory assumption in a public, reusable configuration and could
still map to a different Google identity after rebuild. If the user accepts “a
stable Gmail launcher window” rather than “the installed Gmail Chrome PWA,” the
wrapper is the simpler and more atomic design; its documentation and comments
must describe it accurately.

## Profile and security consequences

`WebAppInstallForceList` is a per-profile policy. A machine platform policy is
loaded for every local Chrome profile, whether or not that profile uses a
managed Google account. On a Mac with several personal/work Chrome profiles,
Gmail may therefore be installed into all of them, and Chrome may consolidate
or migrate their native shortcuts into a multi-profile shim. ([policy per-profile
feature](https://chromeenterprise.google/policies/web-app-install-force-list/),
[platform-policy scope](https://support.google.com/chrome/a/answer/9024365?hl=en))

Consequences:

- A force-installed Gmail app cannot be removed through Chrome while the policy
  remains.
- The Dock path identifies the app bundle, not one Google identity. Chrome owns
  which profile the shim opens and may show a profile chooser when more than one
  profile has the app.
- Gmail authentication, notification permission, and macOS notification/privacy
  approvals are mutable first-run state; declaring the PWA does not declare
  those secrets or approvals.
- Removing the policy should let Chrome reconcile/uninstall the policy-owned
  app. Removing only the Dock entry does not uninstall it.
- A manifest/origin migration can change PWA identity. Google says origin
  migration is blocked for force-installed PWAs until the administrator updates
  the force-install URL, so this policy must be revisited if Google changes the
  Gmail install origin. ([Google's origin-migration
  guidance](https://support.google.com/chrome/a/answer/9367354?hl=en))

If the user wants Gmail in exactly one of several Chrome profiles, a machine-wide
force list is too broad. Chrome Enterprise user policy could target a managed
account, but a personal Gmail account is not eligible for organization user
policy. The honest personal-Mac choices are either force-install it in every
profile or install it once interactively in the chosen profile and accept that
the installation is not fully reconstructed by Nix. ([Google's policy targeting
rules](https://support.google.com/chrome/a/answer/2657289?hl=en))

## Evidence from Nix configurations

Public Nix configurations demonstrate both halves of this pattern, but they are
implementation evidence rather than authority:

- [`alexjmiller5/nix-config`](https://github.com/alexjmiller5/nix-config/blob/f242f0a3e9b44ac801ece380668436a7b7a06b9d/hosts/macbook-air.nix)
  declares `WebAppInstallForceList` and pins a generated
  `~/Applications/Chrome Apps.localized/Google Maps.app` shim. Its use of
  `CustomUserPreferences` should not be copied without confirming mandatory
  policy status in `chrome://policy`.
- [`iamruinous/nix-config`](https://github.com/iamruinous/nix-config/blob/8068a5bf985f1ae793997ff14e6c7476bdb368f2/modules/darwin/desktop/system-settings.nix)
  pins multiple Chrome-created web-app shims from `Chrome Apps.localized`,
  confirming the path shape used by active nix-darwin systems; it does not
  declaratively create those web apps.
- [`wra-bradshaw/.dotfiles`](https://github.com/wra-bradshaw/.dotfiles/blob/4ea39f4ce554eeb7f5e5e953aefd7d41f2199882/darwin/extensions/helium-web-apps.nix)
  generates `WebAppInstallForceList` as a plist, installs it under
  `/Library/Managed Preferences`, and validates the generated shim's URL and
  bundle ID. It targets Helium rather than Google Chrome, but the managed-policy
  and diagnostic pattern matches Chromium's implementation.

Home Manager is not the owner of this feature. Its `programs.chromium` module
documents extensions, command-line arguments, native messaging hosts, and a
package, but it has no web-app policy option. On this repository Chrome itself
is a Homebrew cask, the managed preference is system state, and the Dock is a
nix-darwin system default, so the owning module belongs under `modules/darwin/`.
([Home Manager Chromium options](https://nix-community.github.io/home-manager/options/home-manager/programs/chromium.html))

## Verification required after implementation

Before calling the feature complete on a rebuilt Mac:

1. Run the non-activating Nix checks and system build.
2. Activate and restart Google Chrome.
3. Open `chrome://policy`, reload policies, and verify
   `WebAppInstallForceList` has status **OK**, source **Platform**, and level
   **Mandatory**.
4. Open `chrome://web-app-internals` and verify Gmail's install source and app
   ID.
5. Verify `~/Applications/Chrome Apps.localized/Gmail.app` exists and inspect
   `CrAppModeShortcutID`, `CrAppModeShortcutURL`, profile fields, and
   `CFBundleIdentifier` in its `Info.plist`.
6. Launch the Dock item and confirm whether it opens the intended profile or a
   profile chooser.
7. Reload the Dock only after the shim exists and confirm Gmail appears directly
   after Google Chrome with no question mark.

These checks distinguish a declared policy from a successfully materialized,
correctly routed Gmail app.
