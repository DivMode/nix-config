{
  lib,
  pkgs,
  ...
}:
let
  plist = pkgs.formats.plist { };
  chromePolicy = plist.generate "com.google.Chrome.plist" {
    WebAppInstallForceList = [
      {
        # Google publishes this endpoint specifically for managed Gmail PWA
        # installation. Authentication remains inside each Chrome profile.
        url = "https://mail.google.com/mail/installwebapp?usp=admin";
        default_launch_container = "window";
        fallback_app_name = "Gmail";
        custom_name = "Gmail";
      }
    ];
  };
  policyHash = builtins.hashFile "sha256" chromePolicy;
  policyPath = "/Library/Managed Preferences/com.google.Chrome.plist";
  receiptPath = "/Library/Managed Preferences/.nix-config-com.google.Chrome.sha256";
in
{
  # Chrome's real PWA installer is profile-owned, but its machine policy is
  # system state. A receipt prevents activation from overwriting a policy file
  # created or subsequently changed by another administrator or management tool.
  system.activationScripts.extraActivation.text = lib.mkAfter ''
    policyPath=${lib.escapeShellArg policyPath}
    receiptPath=${lib.escapeShellArg receiptPath}
    expectedHash=${lib.escapeShellArg policyHash}

    if [[ -L "$policyPath" || -L "$receiptPath" ]]; then
      echo "Refusing to replace a symlink at $policyPath or $receiptPath" >&2
      exit 1
    fi

    if [[ -e "$policyPath" ]]; then
      if [[ ! -f "$policyPath" || ! -f "$receiptPath" ]]; then
        echo "Refusing to overwrite unmanaged Chrome policy at $policyPath" >&2
        exit 1
      fi

      recordedHash=$(/bin/cat "$receiptPath")
      actualHash=$(/usr/bin/shasum -a 256 "$policyPath" | /usr/bin/awk '{ print $1 }')
      if [[ "$recordedHash" != "$actualHash" ]]; then
        echo "Refusing to overwrite Chrome policy changed outside nix-config" >&2
        exit 1
      fi
    elif [[ -e "$receiptPath" ]]; then
      echo "Refusing to trust an orphaned Chrome policy receipt at $receiptPath" >&2
      exit 1
    fi

    /bin/mkdir -p "/Library/Managed Preferences"
    /usr/bin/install -m 0644 ${chromePolicy} "$policyPath.new"
    /bin/mv -f "$policyPath.new" "$policyPath"
    /usr/bin/printf '%s\n' "$expectedHash" > "$receiptPath.new"
    /bin/chmod 0644 "$receiptPath.new"
    /bin/mv -f "$receiptPath.new" "$receiptPath"
  '';
}
