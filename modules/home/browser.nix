# Google Chrome is the default browser. modules/darwin/homebrew.nix installs
# the cask and modules/darwin/chrome.nix owns its policy.
#
# Declared here rather than left to Chrome's "Make Google Chrome the default
# browser" checkbox, because that calls LaunchServices' setter, which on
# macOS 27 asks for confirmation ("keep using Safari?") instead of applying.
# ./default-handlers.nix writes the same bindings without the dialog. The
# schemes and types are the ones Chrome's Info.plist declares
# (CFBundleURLTypes "Web site URL"; CFBundleDocumentTypes public.html and
# public.xhtml, both role Viewer). Before this, on 2026-10-05, both schemes
# resolved to Safari.
{ lib, ... }:
let
  chrome = "com.google.Chrome";
in
{
  nixConfig.defaultURLHandlers = lib.genAttrs [ "http" "https" ] (_: chrome);
  nixConfig.defaultHandlers =
    lib.genAttrs
      [
        "public.html"
        "public.xhtml"
      ]
      (_: {
        bundleId = chrome;
        role = "viewer";
      });
}
