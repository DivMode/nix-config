# Vendored VERBATIM (below this header) from homebrew-cask revision
# 341a8ba09fc0861f405f34ebe8a9ffb8e79aab69 — the flake.lock pin this machine
# ran before the 2026-09-01 lock bump. The bump's 26.831.20005 was broken in
# use and the owner asked for this version back. Why and how to unpin is
# documented at the cask declaration in modules/darwin/homebrew.nix; the
# matching Sparkle self-update kill switch is modules/home/chatgpt.nix.
cask "chatgpt" do
  arch arm: "arm64", intel: "x64"
  livecheck_arch = on_arch_conditional intel: "-x64"

  version "26.825.51511"
  sha256 arm:   "db727ef23e561fbd2b47f05fb0fece7dfe839fdb1a081e5a17d34a16a5a0d6c0",
         intel: "4a5fd8d5f5c26fe3f28971bdd776887fe3d0fb62f225ed3a9758e960a11861fd"

  url "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-darwin-#{arch}-#{version}.zip"
  name "ChatGPT"
  desc "OpenAI's official ChatGPT desktop app"
  homepage "https://chatgpt.com/"

  livecheck do
    url "https://persistent.oaistatic.com/codex-app-prod/appcast#{livecheck_arch}.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on macos: :ventura

  app "ChatGPT.app"

  uninstall quit: "com.openai.codex"

  zap trash: [
        "/Library/Application Support/CodexComputerUseAuthorizationPlugin",
        "~/Library/Application Support/Codex",
        "~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/com.openai.codex.sfl*",
        "~/Library/Application Support/com.openai.codex",
        "~/Library/Application Support/OpenAI/Codex",
        "~/Library/Caches/Codex",
        "~/Library/Caches/com.openai.codex",
        "~/Library/Caches/com.openai.sky.CUAService",
        "~/Library/Group Containers/*.com.openai.sky.CUAService",
        "~/Library/HTTPStorages/com.openai.codex",
        "~/Library/HTTPStorages/com.openai.codex.binarycookies",
        "~/Library/HTTPStorages/com.openai.sky.CUAService",
        "~/Library/HTTPStorages/com.openai.sky.CUAService.binarycookies",
        "~/Library/Logs/com.openai.codex",
        "~/Library/Preferences/com.openai.codex.plist",
        "~/Library/Preferences/com.openai.sky.CUAService.cli.plist",
        "~/Library/Preferences/com.openai.sky.CUAService.plist",
        "~/Library/Saved Application State/com.openai.codex.savedState",
      ],
      rmdir: "~/.codex"
end
