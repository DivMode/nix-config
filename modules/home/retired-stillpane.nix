# Retirement of stillpane, removed from this configuration on 2026-09-17.
# Keep this migration for hosts upgrading from a generation that declared it.
# Nothing is installed or created here.
#
# The app itself needs no step: it was a Homebrew cask, and strict cleanup
# ("uninstall", modules/darwin/homebrew.nix) removes a cask that is no longer
# declared. What that cannot reach is the Claude Code plugin, which the old
# module installed through Claude Code's own CLI into ~/.claude/plugins — a
# registered `stillpane` marketplace pointing at a store path, and the plugin
# `stillpane@stillpane` installed from it. Left behind, its UserPromptSubmit
# hook keeps running on every prompt from a store path that garbage collection
# will eventually delete.
#
# `claude plugin marketplace remove` also uninstalls the marketplace's plugins
# (measured against a throwaway CLAUDE_CONFIG_DIR on 2026-09-06, when the
# install was written), so one command retires both. Gated on the registration
# actually being present, so activations after the first change nothing.
#
# Deliberately left alone, as application and user data: the captures under
# ~/.claude/stillpane/, the app's preferences, and its macOS permission grants.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  claude = lib.getExe config.programs.claude-code.finalPackage;
  jq = lib.getExe pkgs.jq;
in
{
  home.activation.retireStillpanePlugin = lib.hm.dag.entryAfter [ "installClaudeSettings" ] ''
    knownMarketplaces="$HOME/.claude/plugins/known_marketplaces.json"
    if [[ -f "$knownMarketplaces" ]] \
      && ${jq} -e 'has("stillpane")' "$knownMarketplaces" >/dev/null 2>&1; then
      run ${claude} plugin marketplace remove stillpane
    else
      verboseEcho "stillpane Claude Code plugin is already retired"
    fi
  '';
}
