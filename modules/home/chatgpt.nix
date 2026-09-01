{
  # The second half of the ChatGPT version pin — the Homebrew half is the
  # vendored cask declared in modules/darwin/homebrew.nix. Remove both
  # together, or neither.
  #
  # Pinning the cask alone would not hold: ChatGPT.app updates ITSELF. The app
  # bundles Sparkle (Contents/Frameworks/Sparkle.framework), and this machine's
  # own domain showed the updater live on 2026-09-01 — SUEnableAutomaticChecks
  # = 1, SUAutomaticallyUpdate = 1, SULastCheckTime that same morning — so a
  # downgraded app would quietly move itself forward again within a day.
  #
  # Sparkle documents exactly these two user-defaults keys as the override for
  # the bundled behaviour (https://sparkle-project.org/documentation/
  # preferences-ui/): EnableAutomaticChecks stops the scheduled check,
  # AutomaticallyUpdate the silent install. A manual "Check for Updates" in the
  # app still works, which is correct — the pin is against unattended drift,
  # not against a deliberate decision to move.
  #
  # The domain is com.openai.codex, NOT com.openai.chat: read from
  # /Applications/ChatGPT.app/Contents/Info.plist CFBundleIdentifier, and it is
  # where the live SU* state above was found. Home Manager applies this with
  # `defaults import`, which merges keys into the domain rather than replacing
  # it — verified on this machine against com.apple.assistant.support, which
  # keeps its full unmanaged dictation tree beside the two keys privacy.nix
  # declares.
  targets.darwin.defaults."com.openai.codex" = {
    SUEnableAutomaticChecks = false;
    SUAutomaticallyUpdate = false;
  };
}
