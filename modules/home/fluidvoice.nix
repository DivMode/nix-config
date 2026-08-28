{ ... }:
{
  # FluidVoice's settings, so a wiped Mac comes back configured rather than
  # stock. The cask is declared in modules/darwin/homebrew.nix; this is the
  # other half.
  #
  # Every value below was READ BACK from ~/Library/Preferences/com.FluidApp.app
  # with plutil rather than guessed, and every one of them is a plain bool,
  # string, integer or real — so none is exposed to the Defaults-library JSON
  # encoding that cost a day in mouse.nix. Anything stored as CFData is
  # deliberately absent; see the hotkey note below and fluidvoice.md.
  #
  # Home Manager applies these with `defaults import`, which MERGES rather than
  # replaces. Verified on 2026-08-27 against the LinearMouse domain, which this
  # repository has declared for weeks: it still holds SUAutomaticallyUpdate,
  # SUEnableAutomaticChecks, SUHasLaunchedBefore, SULastCheckTime,
  # SUSendProfileInfo, SUUpdateGroupIdentifier and autoSwitchToActiveDevice,
  # none of which mouse.nix declares. That matters more here than it did there,
  # because this domain also holds the transcription history — the text of
  # everything ever dictated on this Mac. Nix must never own that, and does not.
  #
  # FluidVoice reads these at launch. Changing a value here therefore takes
  # effect at its next start; there is deliberately NO activation restart, since
  # killing the dictation app mid-sentence to apply a preference is a worse
  # trade than waiting. The values declared here already match what is stored,
  # so nothing needs restarting today.
  targets.darwin.defaults."com.FluidApp.app" = {
    # ── Behaviour ────────────────────────────────────────────────────────
    CopyTranscriptionToClipboard = true;
    DictationPromptOff = false;
    SecondaryDictationPromptOff = true;
    SelectedDictationPromptID = "__FLUID_1__";

    # ── Model and provider ───────────────────────────────────────────────
    # Parakeet TDT v2 runs on-device, which is the reason this application is
    # here rather than a hosted dictation service.
    SelectedSpeechModel = "parakeet-tdt-v2";
    SelectedProviderID = "fluid-1";
    FluidIntelligenceSelectedModelID = "fluid-1";
    PrivateAIProviderContextTokenLimit = 4096;

    # ── Presentation ─────────────────────────────────────────────────────
    LaunchAtStartup = true;
    ShowInDock = false;
    # Two keys, not one duplicate: ShowInDock is the preference, and
    # IntendedDockVisibility is what the application restores from after it has
    # hidden itself. Declaring only the first lets the second put the icon back.
    IntendedDockVisibility = false;
    ShowMainWindowAtLoginLaunch = false;
    ThemePreference = "light";
    OverlayBottomOffset = 50.0;
  };

  # ── NOT DECLARED, on purpose ───────────────────────────────────────────
  #
  # The HOTKEY. HotkeyShortcutKey and PrimaryDictationShortcuts are CFData
  # holding JSON, and AGENTS.md forbids hand-deriving the stored form of a
  # value that is not a plain bool, string or integer — set it in the
  # application's own UI, read the bytes back, declare exactly those. Nix has
  # no bytes type either: `lib.generators.toPlist`, which is what
  # `targets.darwin.defaults` renders through, cannot emit <data> at all, so
  # these need `defaults write -data <hex>` from an activation entry ordered
  # after setDarwinDefaults. That entry is not written yet because the value it
  # would carry has not been chosen. HotkeyMode, PressAndHoldMode and
  # PromptModeShortcutEnabled are withheld with it, as one cluster: they
  # describe how the shortcut fires, and declaring half of a shortcut is how
  # the application and this file end up disagreeing. See fluidvoice.md.
  #
  # The MICROPHONE. PreferredInputDeviceUID, PreferredOutputDeviceUID,
  # MicrophonePriority and MicrophoneSelectionMode all name devices by UID, and
  # a CoreAudio UID embeds the display's hardware serial number. That is
  # machine identity, so it belongs in local.nix if it is ever wanted, never in
  # this public repository.
  #
  # EnableDebugLogs is currently true on this machine. Left alone rather than
  # declared either way, because flipping a diagnostic setting nobody asked
  # about is a change smuggled in under a configuration commit.
  #
  # Everything else in the domain is application state, not desired
  # configuration: the transcription history, command-mode chat sessions,
  # analytics identifiers, the changelog cache, update-snooze timestamps,
  # window frames, onboarding progress, and the various one-shot migration
  # receipts. docs/state-boundary.md draws that line; this is it applied.
}
