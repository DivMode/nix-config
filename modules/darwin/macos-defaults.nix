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
