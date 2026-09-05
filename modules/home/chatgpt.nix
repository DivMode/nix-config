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
  # MEASURED NOT TO HOLD ACROSS AN APP LAUNCH, 2026-09-05, on ChatGPT
  # 26.901.41600: activation wrote both keys false at 21:42:06 local (plist
  # mtime, `defaults read` returned 0 for both); the app was quit and
  # relaunched at 21:42:40 (process start time); by 21:42:50 (plist mtime)
  # `defaults read` returned 1 for both again, with SULastCheckTime unchanged.
  # So the app re-asserts its own preference on every launch, and this
  # declaration is only in force between an activation and the next launch.
  # What actually holds the pin is the postActivation reconcile in
  # modules/darwin/homebrew.nix, which reinstalls from the vendored cask on a
  # version mismatch at every rebuild. Whether to keep this module, replace
  # it with a mechanism the app cannot override, or drop it is an open
  # decision; it is left declared because it costs nothing and is correct
  # for the window it covers.
  targets.darwin.defaults."com.openai.codex" = {
    SUEnableAutomaticChecks = false;
    SUAutomaticallyUpdate = false;
  };
}
