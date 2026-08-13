# SteerMouse, Herdr, and 1Password bootstrap on macOS

Date: 2026-08-12

## Recommendation

Declare SteerMouse as the Homebrew cask `steermouse` through nix-darwin. Keep
the SteerMouse 5 registration information in 1Password, but register the app
interactively after the declarative install. Do not put the ID, CODE, generated
license state, or a decrypted license file in Nix, Home Manager, the public Git
repository, shell history, or the Nix store.

The manual step is not a gap that Nix can safely close: SteerMouse exposes a GUI
registration form but no documented registration command, URL scheme, importable
license file, configuration profile, or unattended activation API. macOS also
requires the user to approve its privacy permissions.

For Herdr, keep installing it with Nix/Home Manager, but pin an official release
tag as the upstream documentation recommends. As of this research, the current
release is `v0.8.0`. The documentation uses
`github:ogulcancelik/herdr/v0.8.0`; GitHub currently redirects both
`ogulcancelik/herdr` and `herdrdev/herdr` to the same repository and commit.

## SteerMouse installation

- The exact Homebrew token is `steermouse`, installed with
  `brew install --cask steermouse`. The current official cask is 5.7.8 and copies
  `SteerMouse.app` into the applications directory. It does not run a package
  installer or a licensing script. [Homebrew cask page](https://formulae.brew.sh/cask/steermouse),
  [cask source](https://github.com/Homebrew/homebrew-cask/blob/HEAD/Casks/s/steermouse.rb)
- SteerMouse 5.7.8 supports macOS Mojave through Tahoe. Version 5.7 made it a
  standalone application instead of a System Settings preference pane.
  [SteerMouse download and release history](https://plentycom.jp/en/steermouse/download.php)
- Homebrew's official `zap` metadata identifies the user's configuration area as
  `~/Library/Application Support/SteerMouse & CursorSense`, its app preferences as
  `~/Library/Preferences/jp.plentycom.app.SteerMouse.plist`, and a launch agent as
  `~/Library/LaunchAgents/jp.plentycom.boa.SteerMouse.plist`. These are application
  state, not a supported unattended license interface.
  [Homebrew cask source](https://github.com/Homebrew/homebrew-cask/blob/HEAD/Casks/s/steermouse.rb)
- The vendor documents `Device.smsetting` in that Application Support directory
  as the mouse **settings** backup/import file. It does not describe it as a
  license file. Importing it requires quitting SteerMouse, replacing the file,
  opening SteerMouse, and choosing Reconfigure.
  [Official SteerMouse FAQ](https://www.plentycom.jp/inc/faq.php?style=e&type=sm)

For this public Nix configuration, the declarative portion should therefore be:

```nix
homebrew.casks = [ "steermouse" ];
```

`Device.smsetting` can be managed later as non-secret user configuration if the
user intentionally exports and reviews it. It should not be confused with the
license.

## License facts and supported registration flow

The SteerMouse registration information has two fields: `ID` and `CODE`. The
vendor calls it a permanent, confidential "short string", permits the purchaser
to use it on multiple computers in their own accounts, and prohibits revealing
or sharing it with other users. [SteerMouse purchase and license terms](https://plentycom.jp/en/steermouse/purchase_v5.html)

The supported registration surface is the app:

1. Open SteerMouse.
2. Open **License & Support**.
3. Choose **Purchase or Enter License**, then enter the `ID` and `CODE`.

The vendor's shipped 5.7.8 app also instructs the user that copying the complete
registration-information email allows the ID and CODE fields to be filled
automatically. The public support page provides email-based reissue of the same
registration information. [SteerMouse support](https://plentycom.jp/en/steermouse/support.html)

No official page, current application bundle, or Homebrew cask documents a CLI
flag or command for registering the product. The bundle contains a GUI login item
(`SteerMouse Manager.app`) and UI strings for ID/CODE entry, but no command-line
registration executable. Consequently, unattended activation would require
unsupported manipulation of private preferences or brittle GUI automation. It
should not be part of `darwin-rebuild`.

The vendor does not document the on-disk location or format of the accepted
license state. Although Homebrew lists preference and Application Support paths
for uninstall cleanup, that is not evidence that copying any one of them is a
portable or supported license mechanism. Treat the 1Password item containing the
original ID/CODE as the source of truth.

## Safe 1Password workflow

Create a 1Password item named `SteerMouse 5` with concealed fields named `ID` and
`CODE`; optionally preserve the complete original registration email in a
concealed notes field. Then, during first-machine bootstrap:

1. Install and sign in to the declared 1Password app.
2. Install SteerMouse through the declared Homebrew cask.
3. Open the SteerMouse registration window.
4. Open the `SteerMouse 5` item in 1Password and copy/paste its fields into the
   app. If the complete registration email was stored, copying that complete text
   uses SteerMouse's own documented auto-fill behavior.
5. Leave 1Password's clipboard-clearing setting enabled. The current 1Password
   app removes copied information after 90 seconds by default.
   [1Password copy-and-fill guidance](https://support.1password.com/copy-passwords/)

1Password CLI can retrieve a field at runtime with an `op://` secret reference,
and 1Password explicitly recommends `op read`, `op run`, or `op inject` so secrets
are not committed in plaintext. [1Password: load secrets into scripts](https://developer.1password.com/docs/cli/secrets-scripts)
However, there is no SteerMouse CLI to receive the retrieved value. Piping
`op read` into `pbcopy` avoids printing it to the terminal, but still places it on
the system clipboard, where clipboard-history tools may capture it. The 1Password
app's own copy flow, with its 90-second clearing behavior, is the safer default.

If a future bootstrap helper is added, it should only verify prerequisites and
open the correct apps/settings pages. It must fetch any secret only at execution
time, never during Nix evaluation or build, and it must not log, cache, write, or
commit the result. License submission must remain a user-confirmed step unless
Plentycom publishes a supported non-interactive interface.

## macOS approvals and restart behavior

SteerMouse Manager needs **Accessibility** and **Input Monitoring**. Apple requires
the user to grant Accessibility access explicitly in System Settings, and Input
Monitoring is controlled per app in Privacy & Security.
[Apple Accessibility permission](https://support.apple.com/guide/mac-help/mh43185/mac),
[Apple Input Monitoring permission](https://support.apple.com/guide/mac-help/mchl4cedafb6/mac)

Inspection of the official 5.7.8 app bundle found no `.systemextension` or `.appex`;
the helper is an embedded login item. The current vendor documentation does not
require a normal reboot after installation. The official FAQ says a **logout** is
needed only after using SteerMouse's "Clear Accessibility" repair action, which
resets privacy registrations. [Official SteerMouse FAQ](https://www.plentycom.jp/inc/faq.php?style=e&type=sm)

Therefore the first-run checklist is:

- launch SteerMouse once;
- grant SteerMouse Manager Accessibility and Input Monitoring when macOS asks;
- register it interactively from 1Password;
- log out only if the Accessibility repair/reset flow is required;
- on an Apple-silicon Mac laptop, separately approve a newly connected USB mouse
  if macOS asks to allow the accessory.
  [Apple accessory approval](https://support.apple.com/102282)

These TCC privacy approvals are intentionally manual on an unmanaged personal Mac.
They can be deployed centrally only through supported device-management policy;
Nix/Home Manager should not modify the TCC database.

## What public dotfile repositories do

Public macOS setup examples found in this review declare `steermouse` as a
Homebrew cask and omit its license. For example, rstacruz's public Brewfile lists
`cask "steermouse"` alongside other native Mac applications, with no registration
automation. [rstacruz Brewfile](https://gist.github.com/rstacruz/b4a719e302c32c20656475e70424df81)

Searches across public Nix/macOS dotfiles did not find a maintained example that
uses Nix, nix-darwin, Home Manager, or 1Password CLI to submit a SteerMouse license.
That negative finding matches the official product surface: package installation
is declarative, while commercial registration and macOS privacy approval remain a
small, explicit first-run checklist. A public repository should follow that split
instead of copying undocumented private app state.

## Herdr verification

Herdr's current official installation documentation supports Homebrew, mise, Nix,
or direct binary installation. For Nix it recommends using a release tag rather
than tracking `master`, and says a flake input should be updated through the
containing flake's normal update and rebuild workflow.
[Herdr install documentation](https://herdr.dev/docs/install/)

The official flake exports `packages.<system>.default` for both Darwin
architectures, so the staged Home Manager package expression is structurally
correct:

```nix
inputs.herdr.packages.${pkgs.system}.default
```

The implementation now uses the canonical release-pinned form from the current
documentation:

```nix
herdr = {
  url = "github:ogulcancelik/herdr/v0.8.0";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

The repository still needs a generated and committed `flake.lock` before
activation. Nothing in this research was installed or activated.
