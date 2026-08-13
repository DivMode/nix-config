{ ... }:
{
  # "Help Apple Improve Search" — the toggle at the bottom of System Settings >
  # Spotlight. On it sends Safari, Siri, Spotlight, Lookup, and #images search
  # queries to Apple. Off is the setting we want, and it is not the default.
  #
  # `2` means explicitly opted out; `1` is opted in and absent means never
  # answered, which behaves as opted in. Both keys are set because the single
  # GUI toggle governs the search and Siri halves together.
  #
  # Key names are from the DISA STIG for macOS 15 (V-269566), not from a blog:
  # https://www.stigviewer.com/stigs/apple_macos_15_sequoia/2026-02-06/finding/V-269566
  targets.darwin.defaults."com.apple.assistant.support" = {
    "Search Queries Data Sharing Status" = 2;
    "Siri Data Sharing Opt-In Status" = 2;
  };
}
