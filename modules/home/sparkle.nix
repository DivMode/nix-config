# Sparkle answers for the self-updating casks.
#
# Every cask here carries Homebrew's `auto_updates` flag and is not `greedy`,
# so `brew upgrade` skips it (see the `upgrade` note in
# ../darwin/homebrew.nix): the application's own Sparkle updater is the only
# thing that keeps it current. Sparkle asks "Check for updates automatically?"
# on an application's second launch unless SUEnableAutomaticChecks is already
# set, and the first answer is stored in the application's defaults domain.
# On 2026-10-05, a new home directory showed that dialog for LinearMouse
# right after activation. IINA and Keka had no stored answer either
# (`defaults read <id> SUEnableAutomaticChecks` failed for both), so each
# would have asked in turn.
#
# Declaring the answer here means no machine asks. Checks and installs both
# on, because "Don't Check" on any of these leaves the application frozen at
# whatever version Homebrew first installed.
#
# ChatGPT.app is deliberately absent: it re-asserts these keys itself on every
# launch (the `chatgpt` entry in ../darwin/homebrew.nix), so it never asks
# and a declaration would hold nothing.
{ lib, ... }:
{
  targets.darwin.defaults =
    lib.genAttrs
      [
        "com.aone.keka"
        "com.colliderli.iina"
        "com.lujjjh.LinearMouse"
      ]
      (_: {
        SUEnableAutomaticChecks = true;
        SUAutomaticallyUpdate = true;
      });
}
