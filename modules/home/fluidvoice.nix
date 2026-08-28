{
  lib,
  ...
}:
let
  # Hyper + S. Caps Lock HELD is Hyper on this machine — modules/home/karabiner.nix
  # emits left_shift + left_command + left_control + left_option for it — so the
  # chord is one comfortable left-hand hold: pinky on Caps Lock, ring finger on S.
  #
  # It replaces plain Shift+S, which was unusable for the obvious reason: Shift+S
  # is how you type a capital S, so dictation fired every time this Mac's owner
  # capitalised one.
  #
  # Hyper+S does not have that problem. FluidVoice matches a shortcut with
  # `modifiers.intersection(relevantModifierMask) == relevantModifierFlags`
  # (Sources/Fluid/Models/HotkeyShortcut.swift), an EQUALITY, so a capital S —
  # which carries Shift and nothing else — cannot match a chord that requires all
  # four.
  #
  # WHY NOT A MODIFIER-ONLY KEY, which is what FluidVoice itself defaults to
  # (Right Option) and what avoids letters altogether. Because in `hold` mode it
  # arms with no threshold. GlobalHotkeyManager.scheduleModifierOnlyStart calls
  # `behavior.onHoldStart()` on the modifier's key-down directly; the only tap
  # threshold in that file, `automaticTapThresholdSeconds = 0.4`, belongs to
  # `automatic` mode. So a modifier-only shortcut starts the microphone the
  # instant its modifier goes down. That is fine for Right Option, a key this
  # keyboard never otherwise uses, and wrong for every LEFT-hand modifier:
  # Left Option would fire on every Option+E accent and every Option-click, Left
  # Control on every terminal Ctrl-C. The press is discarded on release —
  # `wasCleanPress` goes false once another key joins — but the microphone has
  # already opened. Left-handed and modifier-only are not compatible here.
  #
  # Holding the chord does not type `sssss`. The tap consumes a matching
  # key-down: GlobalHotkeyManager returns nil from the event tap for the primary
  # shortcut, auto-repeats included.
  #
  # The cost is a dependency on Karabiner: without it Caps Lock is Caps Lock, so
  # dictation stops AND the keyboard latches into capitals. karabiner.md records
  # how that chain breaks. It is a dependency this keyboard already has for its
  # arrow keys and its Escape.
  hyperFlags =
    131072 # NSEventModifierFlagShift    1 << 17
    + 262144 # NSEventModifierFlagControl  1 << 18
    + 524288 # NSEventModifierFlagOption   1 << 19
    + 1048576; # NSEventModifierFlagCommand  1 << 20

  dictationShortcut = {
    # `kind` is FluidVoice's own ShortcutKind enum: keyboard or mouse.
    kind = "keyboard";
    modifierFlagsRawValue = hyperFlags;
    # kVK_ANSI_S. Not a modifier key code, so FluidVoice treats this as an
    # ordinary chord rather than a modifier-only shortcut, and `modifierKeyCodes`
    # is correctly absent — its encoder omits the field unless the trigger key is
    # itself a modifier.
    keyCode = 1;
  };

  # Written as JSON from a typed Nix attribute set rather than as a hand-authored
  # blob, so the structure above is what gets reviewed and the encoding is
  # mechanical.
  escapedDomain = lib.escapeShellArg "com.FluidApp.app";

  hotkeyData = {
    HotkeyShortcutKey = builtins.toJSON dictationShortcut;
    PrimaryDictationShortcuts = builtins.toJSON [ dictationShortcut ];
  };
in
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
    # ── The hotkey, plain half ───────────────────────────────────────────
    # Push-to-talk: hold the chord, speak, release. The chord itself is CFData
    # and is written by the activation entry below, but these three belong with
    # it — declaring half a shortcut is how the application and this file come
    # to disagree.
    HotkeyMode = "hold";
    PressAndHoldMode = true;
    PromptModeShortcutEnabled = false;

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

  # The two CFData halves of the shortcut.
  #
  # They cannot go in the block above. `targets.darwin.defaults` renders through
  # `lib.generators.toPlist`, which has no <data> output and no bytes type, and
  # FluidVoice stores both of these as CFData holding JSON — verified by reading
  # the domain back, not assumed. So they are written with `defaults write -data`,
  # which takes hex, ordered after setDarwinDefaults so the two writers to this
  # domain cannot race.
  home.activation.installFluidVoiceHotkey =
    lib.hm.dag.entryAfter
      [
        "writeBoundary"
        "setDarwinDefaults"
      ]
      (
        let
          writeOne = key: json: ''
            desired=${lib.escapeShellArg json}

            # Compared before writing, and the comparison is on the DECODED JSON
            # rather than on bytes, so a re-ordered but equivalent encoding does
            # not read as a change. `defaults read` prints CFData as
            # `{length = N, bytes = 0x...}`, which is why the value is taken
            # through `defaults export` and plutil instead.
            current=$(
              /usr/bin/defaults export ${escapedDomain} - 2>/dev/null \
                | /usr/bin/plutil -extract ${lib.escapeShellArg key} raw -o - - 2>/dev/null \
                | /usr/bin/base64 -d 2>/dev/null || true
            )

            if [ "$current" != "$desired" ]; then
              run /usr/bin/defaults write ${escapedDomain} ${lib.escapeShellArg key} \
                -data "$(printf '%s' "$desired" | /usr/bin/xxd -p | /usr/bin/tr -d '\n')"
              hotkeyChanged=1
            fi
          '';
        in
        ''
          hotkeyChanged=0
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList writeOne hotkeyData)}

          # Restart ONLY when the shortcut actually changed.
          #
          # Necessary because FluidVoice reads its preferences at launch: without
          # it a changed chord does not take effect, and the running process can
          # write its stale in-memory value back over ours. Gated because the
          # alternative is killing the dictation application on every unrelated
          # rebuild, mid-sentence. This is the `cmp -s` rule from AGENTS.md, with
          # the decoded JSON standing in for the file comparison.
          if [ "$hotkeyChanged" -eq 1 ]; then
            if /usr/bin/pgrep -x FluidVoice >/dev/null 2>&1; then
              run /usr/bin/pkill -x FluidVoice || true

              # WAIT for the process to actually go. Opening while LaunchServices
              # is still tearing the old one down fails with -600, procNotFound,
              # and the branch then falls through having killed the dictation
              # application and started nothing. Measured on 2026-08-27: the very
              # first activation of this entry printed
              # "_LSOpenURLsWithCompletionHandler() failed with error -600" and
              # left FluidVoice down.
              waited=0
              while /usr/bin/pgrep -x FluidVoice >/dev/null 2>&1 && [ "$waited" -lt 50 ]; do
                /bin/sleep 0.1
                waited=$((waited + 1))
              done
            fi

            # Launched from the bundle rather than by exec'ing the executable, so
            # the process keeps one LaunchServices and TCC identity across a
            # reboot and an activation — FluidVoice holds Accessibility and
            # Microphone grants, and both are keyed on that identity. `-g` avoids
            # stealing focus, `-j` starts it hidden.
            #
            # Retried, because the wait above cannot prove LaunchServices has
            # finished its own bookkeeping, and because leaving dictation dead is
            # a worse outcome than a second attempt. Reports rather than fails:
            # activation aborting here would leave a correct configuration
            # looking like a broken rebuild.
            opened=0
            attempt=0
            while [ "$attempt" -lt 5 ]; do
              if run /usr/bin/open -gj /Applications/FluidVoice.app 2>/dev/null; then
                opened=1
                break
              fi
              attempt=$((attempt + 1))
              /bin/sleep 0.5
            done

            if [ "$opened" -eq 0 ]; then
              echo "warning: FluidVoice was stopped to apply its new shortcut but could not be relaunched; open it manually" >&2
            fi
          fi
        ''
      );

  # ── NOT DECLARED, on purpose ───────────────────────────────────────────
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
