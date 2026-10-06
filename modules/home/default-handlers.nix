# Default document handlers: which application opens a file type when it is
# double-clicked, and which one opens a URL scheme. ./archives.nix, ./media.nix
# and ./terminal.nix declare `nixConfig.defaultHandlers`, ./browser.nix
# declares `nixConfig.defaultURLHandlers`; this module applies all of them.
#
# Not with `duti -s`. On macOS 27 that call (LSSetDefaultRoleHandlerForContentType)
# does not change a type another application already holds: it queues a
# CoreServicesUIAgent dialog asking "Do you want all documents with the
# extension … to open with …, or keep using …?" and still exits 0. Measured
# 2026-10-05 after the first activation of a new home directory: 34 such
# dialogs were open, all owned by CoreServicesUIAgent, while `duti -d` showed
# exactly the uncontested types bound (io.iina.mkv to IINA, rar to Keka) and
# every contested one still on its incumbent (public.mpeg-4 on QuickTime
# Player, public.mp3 on Music, 7z on Archive Utility, shell scripts on
# Terminal).
#
# A binding the owner chooses is stored in the LSHandlers array of the
# com.apple.launchservices.secure preferences domain; the one dialog answered
# "Use Ghostty" that day appeared there as
#   { LSHandlerContentType = "public.unix-executable";
#     LSHandlerRoleShell = "com.mitchellh.ghostty";
#     LSHandlerPreferredVersions = { LSHandlerRoleShell = "-"; }; }
# So the declared bindings are merged into that domain through `defaults`
# (cfprefsd, not the file on disk), and the per-user lsd, which holds the
# handler table in memory, is restarted so it reads them. Both happen only
# when the merge changed something.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nixConfig.defaultHandlers;
  urlCfg = config.nixConfig.defaultURLHandlers;
  desired = pkgs.writeText "default-handlers.json" (
    builtins.toJSON {
      contentTypes = cfg;
      urlSchemes = urlCfg;
    }
  );
in
{
  options.nixConfig.defaultHandlers = lib.mkOption {
    description = ''
      Default handler for each UTI, keyed by the identifier the extension
      actually resolves to on this machine. `role` must be one the
      application's Info.plist declares for that type (CFBundleTypeRole).
    '';
    default = { };
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          bundleId = lib.mkOption { type = lib.types.str; };
          role = lib.mkOption {
            type = lib.types.enum [
              "all"
              "viewer"
              "editor"
              "shell"
            ];
          };
        };
      }
    );
  };

  options.nixConfig.defaultURLHandlers = lib.mkOption {
    description = ''
      Default handler for each URL scheme, as a bundle identifier. The
      application must list the scheme in its Info.plist CFBundleURLTypes.
    '';
    default = { };
    type = lib.types.attrsOf lib.types.str;
  };

  config = lib.mkIf (cfg != { } || urlCfg != { }) {
    home.activation.setDefaultHandlers = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      handlersPlist=$(mktemp)
      # A plain assignment, so a failed merge aborts activation under set -e.
      handlersMerge=$(${pkgs.python3}/bin/python3 -I ${./default-handlers.py} ${desired} "$handlersPlist")
      if [[ $handlersMerge == changed ]]; then
        run /usr/bin/defaults import com.apple.LaunchServices/com.apple.launchservices.secure "$handlersPlist"
        # Only this user's lsd; the root one serves the system domain.
        run /usr/bin/pkill -U "$UID" -x lsd || true
      fi
      rm -f "$handlersPlist"
    '';
  };
}
