{ lib, ... }:
{
  # LinearMouse's documented configuration interface. Match the device category
  # instead of a particular receiver so this works with Bluetooth and future MX
  # mice while leaving trackpad natural scrolling untouched.
  xdg.configFile."linearmouse/linearmouse.json".text = builtins.toJSON {
    "$schema" = "https://schema.linearmouse.app/0.11.4";
    schemes = [
      {
        "if".device.category = "mouse";
        scrolling.reverse.vertical = true;
      }
    ];
  };

  # LinearMouse's own login-item checkbox is mutable GUI state. Home Manager
  # starts the declared cask in the Aqua session instead.
  launchd.agents.linearmouse = {
    enable = true;
    config = {
      ProgramArguments = [ "/Applications/LinearMouse.app/Contents/MacOS/LinearMouse" ];
      RunAtLoad = true;
      KeepAlive = false;
      ProcessType = "Interactive";
      LimitLoadToSessionType = "Aqua";
    };
  };

  # Home Manager's launchd module installs a real plist rather than a symlink.
  # Refuse to replace an unrelated or locally edited file before any activation
  # writes occur; only the current or previous Home Manager generation is owned.
  home.activation.validateLinearMouseLaunchAgent = lib.hm.dag.entryBefore [ "writeBoundary" ] ''
    agentName="org.nix-community.home.linearmouse.plist"
    destination="$HOME/Library/LaunchAgents/$agentName"

    if [[ -L "$destination" ]]; then
      errorEcho "Refusing to replace unmanaged symlink: $destination"
      exit 1
    fi

    if [[ -e "$destination" ]]; then
      owned=false
      newAgent="$newGenPath/LaunchAgents/$agentName"
      if [[ -f "$newAgent" ]] && /usr/bin/cmp -s "$destination" "$newAgent"; then
        owned=true
      fi

      if [[ "$owned" == false && -n "''${oldGenPath:-}" ]]; then
        oldAgent="$oldGenPath/LaunchAgents/$agentName"
        if [[ -f "$oldAgent" ]] && /usr/bin/cmp -s "$destination" "$oldAgent"; then
          owned=true
        fi
      fi

      if [[ "$owned" == false ]]; then
        errorEcho "Refusing to replace unmanaged or modified launch agent: $destination"
        exit 1
      fi
    fi
  '';
}
