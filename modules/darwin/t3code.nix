{
  lib,
  local,
  pkgs,
  ...
}:
let
  # T3 Code (the `t3-code` cask in ./homebrew.nix) is the control plane for
  # the lead-agent setup: one thread hands work to Claude, Codex and
  # Antigravity threads in their own worktrees (`delegate_task`), scheduled
  # tasks start work on a timer, and finished threads land in its inbox.
  #
  # It reads this machine policy at startup (docs/user/managed-policy.md in
  # pingdotgg/t3code). The policy exists for two reasons:
  #
  # - Telemetry off. T3 Code sends product usage events by default, and until
  #   v0.1.12 (2026-11-25; pingdotgg/t3code#42299) it read the account IDs in
  #   ~/.claude.json and ~/.codex/auth.json and sent their unsalted hashes.
  #   `telemetry: false` turns off usage events and relay tracing for the
  #   server, the desktop app and the browsers it opens. The file must exist
  #   before the app first starts, so it is installed by activation.
  # - Our agents, not T3's. Each provider is pinned to this machine's own
  #   launcher, so a T3 thread runs the same `claude` (managed hooks, guards,
  #   plugin dirs), `codex` (ChatGPT.app's CLI and its managed requirements)
  #   and `agy` as a terminal session. Locking `codex` also disables T3's
  #   ChatGPT-managed Codex runtime; pinning `agy` replaces its managed
  #   Antigravity download.
  #
  # T3 refuses to start on an invalid policy or one with keys newer than the
  # installed version, so change it only together with `t3 policy check`.
  bin = name: "/etc/profiles/per-user/${local.user}/bin/${name}";
  pinned = name: {
    locked = true;
    binaryPath = bin name;
  };
  policy = pkgs.writeText "t3code-policy.json" (
    builtins.toJSON {
      schemaVersion = 1;
      organization = "nix-config";
      # Claude and Codex instances are on by default; Antigravity's is off
      # until enabled. A policy may only add an instance users cannot remove,
      # so it is locked (`t3 policy check` refuses `locked = false` here).
      settings."providerInstances.antigravity" = {
        value = {
          driver = "antigravity";
          enabled = true;
        };
        locked = true;
      };
      limits = {
        telemetry = false;
        providers = {
          allowedDrivers = [
            "claudeAgent"
            "codex"
            "antigravity"
          ];
          instances = {
            claudeAgent = pinned "claude";
            codex = pinned "codex";
            antigravity = pinned "agy";
          };
        };
      };
    }
  );
  directory = "/Library/Application Support/T3Code";
  target = "${directory}/policy.json";
  receipt = "${directory}/.nix-config-policy.sha256";

  # Install only bytes this repository wrote. A policy that someone else put
  # there (no receipt, or bytes the receipt does not match) stops activation.
  installPolicy = pkgs.writeShellApplication {
    name = "install-t3code-policy";
    text = ''
      directory=${lib.escapeShellArg directory}
      target=${lib.escapeShellArg target}
      receipt=${lib.escapeShellArg receipt}
      expected=$(/usr/bin/shasum -a 256 ${policy} | /usr/bin/awk '{ print $1 }')

      if [ -L "$directory" ] || [ -L "$target" ] || [ -L "$receipt" ]; then
        echo "Refusing to replace a symlink at the T3 Code policy" >&2
        exit 1
      fi
      if [ -e "$target" ]; then
        actual=$(/usr/bin/shasum -a 256 "$target" | /usr/bin/awk '{ print $1 }')
        if [ "$actual" = "$expected" ]; then
          exit 0
        fi
        if [ ! -f "$receipt" ] || [ "$(/bin/cat "$receipt")" != "$actual" ]; then
          echo "Refusing to overwrite a T3 Code policy not written by nix-config: $target" >&2
          exit 1
        fi
      fi

      /usr/bin/install -d -o root -g wheel -m 0755 "$directory"
      temporary=$(/usr/bin/mktemp "$directory/.policy.XXXXXX")
      /usr/bin/install -o root -g wheel -m 0644 ${policy} "$temporary"
      /bin/mv -f "$temporary" "$target"
      /usr/bin/printf '%s\n' "$expected" > "$receipt"
      /bin/chmod 0644 "$receipt"
    '';
  };
in
{
  system.activationScripts.extraActivation.text = lib.mkAfter ''
    echo "installing the T3 Code machine policy..."
    ${lib.getExe installPolicy}
  '';
}
