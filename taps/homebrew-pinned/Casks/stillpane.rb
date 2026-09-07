# Written for this repository, not vendored: no upstream homebrew-cask entry
# for stillpane exists, and the tap its README offers — `brew install --cask
# yayamaz/tap/stillpane`, i.e. github.com/yayamaz/homebrew-tap — returned 404
# on 2026-09-06 (the account's public repositories were `stillpane` and
# `analyze-youtube-skill`, nothing named homebrew-*). The remaining official
# installers are a dmg download and the plugin's stillpane-install skill, which
# copies into /Applications by hand; neither is state this repository can
# reconcile, so the cask is written here from the release itself.
#
# The dmg is a versioned GitHub release asset; the sha256 was computed from a
# local download of exactly that asset on 2026-09-06, and the bundle inside it
# was read the same day: CFBundleIdentifier app.stillpane.Stillpane,
# CFBundleShortVersionString 1.1.1, LSMinimumSystemVersion 14.0, signed
# "Developer ID Application: Yanis Saheb (7NV7GLDW87)".
#
# No `auto_updates`: the app only ever CHECKS stillpane.dev for a newer
# version and offers a link to the release page (docs/how-it-works.md,
# "Its only network activity"); it never installs one. So `brew upgrade` is
# the right owner of upgrades here. `version` and `sha256` below are moved by
# `./scripts/update.sh` (on a full run, or `./scripts/update.sh stillpane`)
# from the project's latest GitHub release, together with the `stillpane-src`
# tag in flake.nix that carries the Claude Code plugin the same release ships.
cask "stillpane" do
  version "1.1.1"
  sha256 "2759e5d32f00869d7b3d6ada9b936d90c28268b92263f9ff4541ef843c97017e"

  url "https://github.com/yayamaz/stillpane/releases/download/v#{version}/stillpane-#{version}.dmg"
  name "stillpane"
  desc "Attach the active window or webpage to the next Claude Code prompt"
  homepage "https://stillpane.dev/"

  depends_on macos: :sonoma

  app "stillpane.app"

  uninstall quit: "app.stillpane.Stillpane"

  zap trash: [
        "~/Library/Preferences/app.stillpane.Stillpane.plist",
      ]
end
