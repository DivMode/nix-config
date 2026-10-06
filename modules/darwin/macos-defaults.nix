{ local, ... }:
{
  system.defaults = {
    NSGlobalDomain = {
      ApplePressAndHoldEnabled = false;
      InitialKeyRepeat = 15;
      KeyRepeat = 2;
      NSNavPanelExpandedStateForSaveMode = true;
      NSNavPanelExpandedStateForSaveMode2 = true;
      "com.apple.swipescrolldirection" = true;
    };

    finder = {
      AppleShowAllExtensions = true;
      FXDefaultSearchScope = "SCcf";
      FXPreferredViewStyle = "clmv";
      NewWindowTarget = "Home";
      ShowPathbar = true;
      ShowStatusBar = true;
      _FXEnableColumnAutoSizing = true;
      _FXSortFoldersFirst = true;
    };

    loginwindow.GuestEnabled = false;

    # Never install macOS updates automatically. An unattended major-version
    # upgrade reboots the machine and can break the toolchain without warning.
    # Checking and downloading are left at their defaults, so updates are still
    # offered — installing them stays a deliberate act.
    SoftwareUpdate.AutomaticallyInstallMacOSUpdates = false;

    # No `screensaver` block. askForPassword/askForPasswordDelay are not what
    # macOS 27 reads: on 2026-10-06 the domain held askForPasswordDelay = 60
    # while `sysadminctl -screenLock status` reported "screenLock delay is 300
    # seconds". The real setting lives behind sysadminctl and needs the
    # user's password, so it cannot be declared here.

    screencapture = {
      location = "${local.homeDirectory}/Documents/Screenshots";
      target = "file";
    };

    WindowManager = {
      StandardHideWidgets = true;
      StageManagerHideWidgets = true;
    };
  };
}
