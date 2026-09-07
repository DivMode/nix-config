{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  # stillpane's Claude Code plugin, cut from the release tree the `stillpane-src`
  # flake input pins: the repository root IS the plugin (.claude-plugin/
  # plugin.json, hooks/, skills/). Its two hooks attach a fresh window capture
  # from ~/.claude/stillpane/ to the next prompt and approve reading it without
  # a permission dialog; `/stillpane` pulls in an older capture.
  #
  # Only the plugin's own files are copied; the Swift sources, tests and assets
  # beside them are the app, not the plugin, and Claude Code has no business
  # scanning them.
  #
  # The `stillpane-install` skill is left out. It downloads the release dmg and
  # copies the app into /Applications by hand, which is exactly the imperative
  # install the `nix-config/pinned/stillpane` cask in modules/darwin/homebrew.nix
  # replaces — two installers for one path would fight over it. Leaving it out
  # also drops the hook's one-time "install it?" offer, which keys on
  # /Applications/stillpane.app being absent.
  plugin = pkgs.runCommand "stillpane-claude-plugin" { } ''
    mkdir -p $out/skills
    cp -r ${inputs.stillpane-src}/.claude-plugin $out/
    cp -r ${inputs.stillpane-src}/hooks $out/
    cp -r ${inputs.stillpane-src}/skills/stillpane $out/skills/
    cp ${inputs.stillpane-src}/LICENSE ${inputs.stillpane-src}/NOTICE $out/
  '';

  # A one-plugin marketplace wrapped around that tree, so the plugin can be
  # installed under the id `stillpane@stillpane` — the marketplace's name, then
  # the plugin's.
  #
  # WHY A MARKETPLACE AND NOT `programs.claude-code.plugins`. That option loads
  # a plugin with `--plugin-dir`, which is how mattpocock-skills and gcx are
  # loaded, and it worked for the hooks. But a plugin loaded that way is listed
  # by `claude plugin list --json` as `stillpane@inline`, and the stillpane
  # app's setup assistant looks for exactly `stillpane@stillpane`
  # (Sources/Stillpane/ClaudeCLI.swift, installedPluginVersion). Its "Connect
  # Claude Code" step has no way past without that id — the view's own comment
  # reads "there is no way past this step without it - Continue only exists
  # once the install landed" (Onboarding/OnboardingView.swift) — so with the
  # inline form the assistant reopened on that step at every launch, forever.
  #
  # The id it wants is only ever produced by a marketplace install, so this is
  # one. Upstream's own install path, `/plugin marketplace add
  # yayamaz/stillpane`, would clone GitHub into ~/.claude/plugins; this one
  # hands Claude Code a directory in the store, and its `source: directory`
  # marketplace kind registers that path in place rather than copying it
  # (the same encoding home-manager's claude-code module uses for its
  # `marketplaces` option).
  marketplace = pkgs.runCommand "stillpane-claude-marketplace" { } ''
    mkdir -p $out/.claude-plugin $out/plugins
    cp -r ${plugin} $out/plugins/stillpane
    cp ${
      pkgs.writeText "marketplace.json" (
        builtins.toJSON {
          name = "stillpane";
          owner.name = "nix-config";
          plugins = [
            {
              name = "stillpane";
              source = "./plugins/stillpane";
              description = "Auto-attach stillpane window captures to your next Claude Code message";
            }
          ];
        }
      )
    } $out/.claude-plugin/marketplace.json
  '';

  claude = lib.getExe config.programs.claude-code.finalPackage;
  jq = lib.getExe pkgs.jq;
in
{
  # The install itself goes through Claude Code's own CLI, at activation.
  #
  # Claude Code does not install a plugin because settings name it — its docs
  # are explicit that `enabledPlugins` and `extraKnownMarketplaces` register
  # and enable, and "users must still run /plugin install". So the install is
  # driven here, with the same two commands the app's assistant would run,
  # pointed at the store instead of GitHub. What they write —
  # ~/.claude/plugins/known_marketplaces.json, installed_plugins.json, and a
  # copy of the plugin under plugins/cache/stillpane/stillpane/<version> — is
  # Claude Code's own state, and it is regenerated from this file on every
  # activation that finds it missing or different. That is the same shape as
  # the settings.json merge in ./ai: desired state declared here, written
  # through the application's interface because the application also writes
  # the file.
  #
  # Every branch was tried against a throwaway CLAUDE_CONFIG_DIR on
  # 2026-09-06 before being relied on:
  #   * `marketplace add <path>` is idempotent for an unchanged path
  #     ("already on disk"), and RE-POINTS a marketplace of the same name at a
  #     new path — which is what a new store path after a version bump is.
  #   * `marketplace remove` also UNINSTALLS the plugin, so it is never used
  #     here; a stale path is corrected by adding over it.
  #   * `plugin install` is idempotent ("already installed").
  #   * The cache copy is a byte-for-byte copy of the plugin directory, so
  #     `diff -r` against the store is an exact drift check. On drift the
  #     plugin is uninstalled and installed again rather than `plugin update`d,
  #     because update keys on the version in plugin.json and would skip a
  #     content change that kept the number.
  #
  # Ordered after ./ai's settings merge because `marketplace add` writes
  # `extraKnownMarketplaces` and `enabledPlugins` into ~/.claude/settings.json;
  # the merge preserves unknown keys, but running afterwards means it never
  # reads a file mid-write.
  home.activation.installStillpanePlugin = lib.hm.dag.entryAfter [ "installClaudeSettings" ] ''
    stillpaneMarketplace=${marketplace}
    knownMarketplaces="$HOME/.claude/plugins/known_marketplaces.json"

    registeredPath="$(${jq} -r '.stillpane.source.path // empty' "$knownMarketplaces" 2>/dev/null || true)"
    if [[ "$registeredPath" != "$stillpaneMarketplace" ]]; then
      run ${claude} plugin marketplace add "$stillpaneMarketplace"
    fi

    installedPath="$(
      ${claude} plugin list --json 2>/dev/null \
        | ${jq} -r '.[] | select(.id == "stillpane@stillpane") | .installPath' 2>/dev/null \
        || true
    )"
    if [[ -z "$installedPath" ]]; then
      run ${claude} plugin install stillpane@stillpane
    elif ! /usr/bin/diff -rq "$installedPath" "$stillpaneMarketplace/plugins/stillpane" >/dev/null 2>&1; then
      run ${claude} plugin uninstall stillpane@stillpane
      run ${claude} plugin install stillpane@stillpane
    else
      verboseEcho "stillpane Claude Code plugin is already current"
    fi
  '';

  # Version checks are this repository's job, not the app's.
  #
  # stillpane never updates itself: UpdateChecker.swift only fetches
  # stillpane.dev/version.json once a day and, if that names a newer release,
  # adds a menu item linking to the release page. The app's version is pinned
  # by the cask in taps/homebrew-pinned/Casks/stillpane.rb, and
  # scripts/update.sh already reports the `stillpane-src` tag pin against the
  # latest GitHub release on every run — so the in-app check could only ever
  # nag about a release this repository has not adopted yet, and stays off.
  #
  # `checkForUpdatesAutomatically` is the literal key UpdateChecker reads
  # (`static let automaticKey`), as a plain Bool with a default of true; the
  # app writes it only when its menu toggle is used, so a declared value holds.
  targets.darwin.defaults."app.stillpane.Stillpane".checkForUpdatesAutomatically = false;
}
