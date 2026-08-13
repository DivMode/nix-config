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

    screensaver = {
      # Lock behind the screen saver rather than trusting physical presence.
      askForPassword = true;
      # One minute of grace, so briefly nudging the mouse does not demand a
      # password, but walking away does. Pairs with the 20-minute idle timer in
      # modules/home/screensaver.nix.
      askForPasswordDelay = 60;
    };

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
