{
  ai,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  ccstatusline = import ../home/ai/ccstatusline.nix { inherit inputs lib pkgs; };
  hooks = import ai.hooks {
    inherit pkgs;
    inherit (ccstatusline) statusLine;
  };
  policyDirectory = "/Library/Application Support/ClaudeCode";
  policyPath = "${policyDirectory}/managed-settings.json";
  receiptPath = "${policyDirectory}/.nix-config-managed-settings.sha256";

  # Agent hooks exist only in ai/hooks/default.nix. Repositories cannot add
  # hooks: both clients enforce managed-only loading. The build contract runs
  # every handler with broken and harmless inputs before producing either
  # policy. Every command runs through the pinned-Python supervisor: observers
  # emit no stdout, failures/timeouts exit 0, and only validated PreToolUse
  # permission denials can pass through. Turn-controlling events are banned.
  #
  # Claude refuses to start if its managed file is not a JSON object. Install
  # only the contract's validated output, with a same-directory atomic rename
  # and Chrome's receipt/collision guard. No reconciler: unlike Chrome's
  # /Library/Managed Preferences, macOS does not wipe this directory at boot.
  installPolicy = pkgs.writeShellApplication {
    name = "install-managed-agent-hooks";
    derivationArgs.postCheck = ''
      ${lib.getExe pkgs.python3} ${./agent-hooks-policy-test.py} \
        "$target" ${hooks.managed}/managed-settings.json ${lib.getExe pkgs.bash}
    '';
    text = ''
      policyDirectory=${lib.escapeShellArg policyDirectory}
      policyPath=${lib.escapeShellArg policyPath}
      receiptPath=${lib.escapeShellArg receiptPath}
      expectedHash=$(/usr/bin/shasum -a 256 ${hooks.managed}/managed-settings.json | /usr/bin/awk '{ print $1 }')

      writeReceipt() {
        local receiptTemp
        receiptTemp=$(/usr/bin/mktemp "$policyDirectory/.nix-config-receipt.XXXXXX")
        /usr/bin/printf '%s\n' "$expectedHash" > "$receiptTemp"
        /usr/sbin/chown root:wheel "$receiptTemp"
        /bin/chmod 0644 "$receiptTemp"
        /bin/mv -f "$receiptTemp" "$receiptPath"
      }

      if [ -L "$policyDirectory" ] || [ -L "$policyPath" ] || [ -L "$receiptPath" ]; then
        echo "Refusing to replace a symlink at the Claude managed policy or receipt" >&2
        exit 1
      fi
      if [ -e "$receiptPath" ] && [ ! -f "$receiptPath" ]; then
        echo "Refusing a non-file Claude managed policy receipt" >&2
        exit 1
      fi
      if [ -e "$policyPath" ]; then
        if [ ! -f "$policyPath" ]; then
          echo "Refusing to overwrite unmanaged Claude policy at $policyPath" >&2
          exit 1
        fi
        actualHash=$(/usr/bin/shasum -a 256 "$policyPath" | /usr/bin/awk '{ print $1 }')
        if [ "$actualHash" != "$expectedHash" ]; then
          if [ ! -f "$receiptPath" ]; then
            echo "Refusing to overwrite unmanaged Claude policy at $policyPath" >&2
            exit 1
          fi
          recordedHash=$(/bin/cat "$receiptPath")
          if [ "$recordedHash" != "$actualHash" ]; then
            echo "Refusing to overwrite Claude policy changed outside nix-config" >&2
            exit 1
          fi
        fi
      fi

      /usr/bin/install -d -o root -g wheel -m 0755 "$policyDirectory"
      if [ -f "$policyPath" ] && [ "$actualHash" = "$expectedHash" ]; then
        /usr/sbin/chown root:wheel "$policyPath"
        /bin/chmod 0644 "$policyPath"
        # Recover an interrupted policy rename even if the receipt is missing
        # or still records the previous generation. Other policy bytes must
        # continue to prove ownership against their receipt above.
        if [ ! -f "$receiptPath" ] || [ "$(/bin/cat "$receiptPath")" != "$expectedHash" ]; then
          writeReceipt
        else
          /usr/sbin/chown root:wheel "$receiptPath"
          /bin/chmod 0644 "$receiptPath"
        fi
        exit 0
      fi

      policyTemp=$(/usr/bin/mktemp "$policyDirectory/.managed-settings.XXXXXX")
      /usr/bin/install -o root -g wheel -m 0644 ${hooks.managed}/managed-settings.json "$policyTemp"
      /bin/mv -f "$policyTemp" "$policyPath"
      writeReceipt
    '';
  };
in
{
  environment.etc."codex/requirements.toml".source = "${hooks.managed}/requirements.toml";

  system.activationScripts.extraActivation.text = lib.mkAfter ''
    echo "installing managed agent hooks..."
    ${lib.getExe installPolicy}
  '';
}
