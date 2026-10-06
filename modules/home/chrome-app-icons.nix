# Dock icons for Chrome web apps, set as Finder custom icons.
#
# Chrome writes a web app's icon into its shim (~/Applications/Chrome
# Apps.localized/<name>.app/Contents/Resources/app.icns) from the site's
# manifest, and on macOS 26+ hands a bare manifest icon to the system, which
# draws it shrunk inside a grey tile. Gmail's manifest offers only such a bare
# "M". The policy's custom_icon does not stick: Chrome's silent manifest update
# replaces it the first time the app is opened (see ../darwin/chrome.nix).
#
# A Finder custom icon (Get Info → paste an image; the `Icon\r` file plus the
# custom-icon Finder flag on the bundle) is what the Dock shows instead of
# app.icns, and Chrome does not write it. It is lost only when Chrome rebuilds
# the whole shim — after its silent manifest update or a Chrome update — so
# every rebuild re-applies it when missing. Nothing runs when it is present.
{ config, lib, ... }:
let
  # App name as Chrome names the shim -> icon (a square PNG on Apple's
  # app-icon grid; Gmail's is option 3 of the 2026-10-06 icon page).
  icons = {
    Gmail = ./chrome-app-icons/gmail.png;
  };

  appsDir = "${config.home.homeDirectory}/Applications/Chrome Apps.localized";
  stateDir = "${config.xdg.stateHome}/chrome-app-icons";

  # NSWorkspace -setIcon:forFile:options: is the API behind Get Info's paste.
  setIcon = ''
    function run(argv) {
      ObjC.import("AppKit");
      const image = $.NSImage.alloc.initWithContentsOfFile(argv[0]);
      if (image.isNil()) { throw new Error("cannot read " + argv[0]); }
      if (!$.NSWorkspace.sharedWorkspace.setIconForFileOptions(image, argv[1], 0)) {
        throw new Error("macOS refused to set the icon on " + argv[1]);
      }
    }
  '';
in
{
  home.activation.setChromeAppIcons = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    chromeAppIconsChanged=0
    ${lib.concatStrings (
      lib.mapAttrsToList (name: icon: ''
        app=${lib.escapeShellArg "${appsDir}/${name}.app"}
        marker=${lib.escapeShellArg "${stateDir}/${name}"}
        wanted=${lib.escapeShellArg (builtins.hashFile "sha256" icon)}
        if [[ ! -d "$app" ]]; then
          verboseEcho "Chrome app ${name} is not installed yet; its icon is set on a later rebuild"
        elif [[ -e "$app/Icon"$'\r' && "$(cat "$marker" 2>/dev/null)" == "$wanted" ]]; then
          verboseEcho "Chrome app ${name} already has its custom icon"
        else
          run mkdir -p ${lib.escapeShellArg stateDir}
          run /usr/bin/osascript -l JavaScript -e ${lib.escapeShellArg setIcon} ${icon} "$app"
          if [[ ! -v DRY_RUN ]]; then
            printf '%s\n' "$wanted" > "$marker"
          fi
          chromeAppIconsChanged=1
        fi
      '') icons
    )}
    # The Dock keeps drawing a pinned app's old icon until it restarts, so
    # restart it, but only when an icon was actually set just now.
    if [[ $chromeAppIconsChanged == 1 ]]; then
      run /usr/bin/killall Dock || true
    fi
  '';
}
