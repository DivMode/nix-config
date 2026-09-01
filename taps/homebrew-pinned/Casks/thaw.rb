# Written for this repository, not vendored: upstream homebrew-cask carries
# only Thaw 2.x, which is macOS 26-only ("The minimum deployment target is now
# macOS 26. Systems on macOS 14 or 15 stay on the 1.x line",
# https://github.com/thaw-app/Thaw/releases/tag/2.0.0). 1.2.0 is the newest
# release that runs on macOS 15, and no thaw@1 cask exists upstream. The zip is
# a versioned GitHub release asset; the sha256 was computed from a local
# download of exactly that asset on 2026-09-01.
#
# `auto_updates true` matches upstream's cask and keeps `brew upgrade` away
# from it; Sparkle appcasts gate entries on minimumSystemVersion, so on
# macOS 15 the app's own updater is not expected to offer the 2.x line — but
# that is Sparkle behaviour, not something this file can enforce.
cask "thaw" do
  version "1.2.0"
  sha256 "d67f4d31ef9fa057849a98540b810cfa42e0bc66019d3605abd08e45c69aa06f"

  url "https://github.com/thaw-app/Thaw/releases/download/#{version}/Thaw_#{version}.zip"
  name "Thaw"
  desc "Menu bar manager (1.x line, the last to support macOS 14/15)"
  homepage "https://github.com/thaw-app/Thaw/"

  auto_updates true
  # Symbol form means "this macOS or newer" on current brew — upstream's 2.x
  # cask expresses ">= 26" as exactly `depends_on macos: :tahoe`. The string
  # comparison form (">= :sonoma") is deprecated and warns on every install.
  depends_on macos: :sonoma

  app "Thaw.app"

  uninstall quit: "com.stonerl.Thaw"

  zap trash: [
        "~/Library/Preferences/com.stonerl.Thaw.plist",
      ]
end
