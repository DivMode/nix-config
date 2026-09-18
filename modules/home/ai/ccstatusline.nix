# Claude Code status line, built on ccstatusline.
#
# The two helper scripts and the segment layout are ported from Martin Wimpress'
# nix-config (github.com/wimpysworld/nix-config), which is published under the
# Blue Oak Model License 1.0.0. ccstatusline has no native quota segment, so the
# usage script is the only way to show how much of the rolling window is left.
#
# Returned as a plain attribute set rather than a module so the settings and the
# statusLine value can be consumed by two different owners: the ccstatusline
# config file is a symlink, while Claude Code's settings.json is an activation-
# installed real file. See ../projects.md for why those differ.
{
  inputs,
  lib,
  pkgs,
}:
let
  inherit (pkgs.stdenv.hostPlatform) system;

  package = inputs.llm-agents.packages.${system}.ccstatusline;

  # Catppuccin Mocha, matching the terminal theme declared in ../terminal.nix.
  # ccstatusline wants `hex:RRGGBB` with no leading '#'.
  palette = {
    green = "a6e3a1";
    mauve = "cba6f7";
    peach = "fab387";
    red = "f38ba8";
    yellow = "f9e2af";
  };
  color = name: "hex:${palette.${name}}";

  # Remaining percentage of a rolling usage window. Claude Code does not expose
  # this to the status line, so it is read from the OAuth usage endpoint with
  # the client's own credentials.
  #
  # The cache is the load-bearing part: the status line re-renders on every
  # turn, so an uncached implementation would call the API continuously. Three
  # minutes is well inside the resolution of a five-hour window, and a failed
  # request falls back to the stale cache rather than blanking the segment.
  #
  # The token lives in two different places depending on the platform. Linux
  # gets ~/.claude/.credentials.json; macOS keeps it in the login Keychain and
  # writes no such file, so reading only the file left both quota segments
  # rendering as empty strings behind their labels.
  usageRemaining = pkgs.writeTextFile {
    name = "ccstatusline-usage-remaining";
    destination = "/bin/ccstatusline-usage-remaining";
    executable = true;
    text = ''
      #!${lib.getExe pkgs.nodejs}
      const fs = require("fs");
      const https = require("https");
      const os = require("os");
      const path = require("path");
      const { execFileSync } = require("child_process");

      const bucketName = process.argv[2];
      if (!["five_hour", "seven_day"].includes(bucketName)) {
        process.exit(0);
      }

      const cacheMaxAgeMs = 180 * 1000;
      const home = process.env.HOME || os.homedir();
      const configDir = process.env.CLAUDE_CONFIG_DIR || path.join(home, ".claude");
      const cacheDir = process.env.XDG_CACHE_HOME
        ? path.join(process.env.XDG_CACHE_HOME, "ccstatusline")
        : path.join(home, ".cache", "ccstatusline");
      const cacheFile = path.join(cacheDir, "usage-api.json");

      function printRemaining(data) {
        const bucket = data && Object.prototype.hasOwnProperty.call(data, bucketName)
          ? data[bucketName]
          : undefined;
        const used = bucket === null ? 0 : bucket && bucket.utilization;
        if (typeof used !== "number" || !Number.isFinite(used)) {
          return false;
        }
        const remaining = Math.max(0, Math.min(100, 100 - used));
        process.stdout.write(Math.round(remaining).toString() + "%\n");
        return true;
      }

      function readJson(file) {
        try {
          return JSON.parse(fs.readFileSync(file, "utf8"));
        } catch {
          return null;
        }
      }

      function tryFreshCache() {
        try {
          const stat = fs.statSync(cacheFile);
          if (Date.now() - stat.mtimeMs > cacheMaxAgeMs) {
            return false;
          }
          return printRemaining(readJson(cacheFile));
        } catch {
          return false;
        }
      }

      function tryStaleCache() {
        return printRemaining(readJson(cacheFile));
      }

      function tokenFrom(credentials) {
        const token = credentials
          && credentials.claudeAiOauth
          && credentials.claudeAiOauth.accessToken;
        return typeof token === "string" && token.length > 0 ? token : null;
      }

      // macOS stores the credentials as a login Keychain generic password
      // rather than a file. `security` is a system binary with no nixpkgs
      // equivalent, so it is called by absolute path to stay independent of
      // whatever PATH the status line inherits. A locked Keychain, a missing
      // entry, or a denied prompt all throw, which falls back to the cache.
      function readKeychainToken() {
        if (process.platform !== "darwin") {
          return null;
        }
        try {
          const entry = execFileSync(
            "/usr/bin/security",
            ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
            { encoding: "utf8", timeout: 5000, stdio: ["ignore", "pipe", "ignore"] },
          );
          return tokenFrom(JSON.parse(entry));
        } catch {
          return null;
        }
      }

      function readToken() {
        return tokenFrom(readJson(path.join(configDir, ".credentials.json")))
          || readKeychainToken();
      }

      function fetchUsage(token) {
        const request = https.request({
          hostname: "api.anthropic.com",
          path: "/api/oauth/usage",
          method: "GET",
          timeout: 5000,
          headers: {
            Authorization: "Bearer " + token,
            "anthropic-beta": "oauth-2025-04-20",
          },
        }, (response) => {
          let body = "";
          response.setEncoding("utf8");
          response.on("data", (chunk) => {
            body += chunk;
          });
          response.on("end", () => {
            if (response.statusCode !== 200 || body.length === 0) {
              tryStaleCache();
              return;
            }
            const data = JSON.parse(body);
            fs.mkdirSync(cacheDir, { recursive: true });
            fs.writeFileSync(cacheFile, JSON.stringify(data));
            printRemaining(data);
          });
        });

        request.on("error", tryStaleCache);
        request.on("timeout", () => {
          request.destroy();
          tryStaleCache();
        });
        request.end();
      }

      if (!tryFreshCache()) {
        const token = readToken();
        if (token) {
          fetchUsage(token);
        } else {
          tryStaleCache();
        }
      }
    '';
  };

  # Percentage of the context window consumed. ccstatusline pipes the session
  # JSON on stdin. Prefers an explicit used_percentage when the client supplies
  # one, and otherwise sums the four token counters against the window size,
  # because cache reads and creations count toward the window too.
  contextUsed = pkgs.writeTextFile {
    name = "ccstatusline-context-used";
    destination = "/bin/ccstatusline-context-used";
    executable = true;
    text = ''
      #!${lib.getExe pkgs.nodejs}
      const fs = require("fs");

      function toNumber(value) {
        if (typeof value === "number" && Number.isFinite(value)) {
          return value;
        }
        if (typeof value === "string" && value.trim().length > 0) {
          const parsed = Number(value);
          return Number.isFinite(parsed) ? parsed : null;
        }
        return null;
      }

      function usageTokens(usage) {
        const direct = toNumber(usage);
        if (direct !== null) {
          return direct;
        }
        if (!usage || typeof usage !== "object") {
          return null;
        }
        return [
          usage.input_tokens,
          usage.output_tokens,
          usage.cache_creation_input_tokens,
          usage.cache_read_input_tokens,
        ].reduce((total, value) => total + (toNumber(value) || 0), 0);
      }

      function contextUsedPercentage(data) {
        const contextWindow = data && data.context_window;
        if (!contextWindow || typeof contextWindow !== "object") {
          return 0;
        }

        const explicitUsed = toNumber(contextWindow.used_percentage);
        if (explicitUsed !== null) {
          return explicitUsed;
        }

        const windowSize = toNumber(contextWindow.context_window_size);
        if (!windowSize || windowSize <= 0) {
          return 0;
        }

        const currentUsage = usageTokens(contextWindow.current_usage);
        if (currentUsage !== null) {
          return currentUsage / windowSize * 100;
        }

        const totalInput = toNumber(contextWindow.total_input_tokens) || 0;
        const totalOutput = toNumber(contextWindow.total_output_tokens) || 0;
        return (totalInput + totalOutput) / windowSize * 100;
      }

      try {
        const data = JSON.parse(fs.readFileSync(0, "utf8"));
        const used = Math.max(0, Math.min(100, contextUsedPercentage(data)));
        process.stdout.write(Math.round(used).toString() + "%\n");
      } catch {
        process.stdout.write("0%\n");
      }
    '';
  };
in
{
  inherit package;

  # Written to Claude Code's settings.json, which reads it on startup to invoke
  # the formatter.
  statusLine = {
    type = "command";
    command = lib.getExe package;
    padding = 0;
  };

  # Written to ~/.config/ccstatusline/settings.json.
  #
  # Plain values only. `builtins.toJSON` serialises a `lib.mkDefault` wrapper
  # verbatim as an attribute set, which then fails ccstatusline's Zod schema
  # validation at runtime rather than at build time.
  settings = {
    version = 4;
    flexMode = "full";
    compactThreshold = 60;
    colorLevel = 2;
    defaultPadding = "";
    defaultSeparator = " · ";
    inheritSeparatorColors = false;
    globalBold = false;
    powerline = {
      enabled = false;
      separators = [ "" ];
      separatorInvertBackground = [ false ];
      startCaps = [ ];
      endCaps = [ ];
      autoAlign = false;
    };
    lines = [
      [
        {
          id = "1";
          type = "model";
          color = color "yellow";
          rawValue = true;
        }
        {
          id = "2";
          type = "thinking-effort";
          color = color "mauve";
          rawValue = true;
        }
        {
          id = "3";
          type = "current-working-dir";
          color = color "green";
          rawValue = true;
          metadata.abbreviateHome = "true";
        }
        {
          id = "4";
          type = "custom-text";
          color = color "red";
          customText = "5h ";
          merge = "no-padding";
        }
        {
          id = "5";
          type = "custom-command";
          color = color "red";
          commandPath = "${lib.getExe usageRemaining} five_hour";
          timeout = 1000;
        }
        {
          id = "6";
          type = "custom-text";
          color = color "red";
          customText = "weekly ";
          merge = "no-padding";
        }
        {
          id = "7";
          type = "custom-command";
          color = color "red";
          commandPath = "${lib.getExe usageRemaining} seven_day";
          timeout = 1000;
        }
        {
          id = "8";
          type = "context-window";
          color = color "peach";
          rawValue = true;
          merge = "no-padding";
        }
        {
          id = "9";
          type = "custom-text";
          color = color "peach";
          customText = " window";
        }
        {
          id = "10";
          type = "custom-text";
          color = color "peach";
          customText = "Context ";
          merge = "no-padding";
        }
        {
          id = "11";
          type = "custom-command";
          color = color "peach";
          commandPath = lib.getExe contextUsed;
          timeout = 1000;
          merge = "no-padding";
        }
        {
          id = "12";
          type = "custom-text";
          color = color "peach";
          customText = " used";
        }
      ]
    ];
  };
}
