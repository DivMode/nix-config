# Herdr's runtime configuration and workflow plugins.
#
# Herdr is the persistent workspace and pane manager that runs inside Ghostty;
# ../terminal.nix declares the terminal, and ../development.nix installs the
# binary. This module owns what Herdr reads at run time, which until now was
# entirely undeclared: a config.toml written by hand and a plugin set that did
# not exist.
#
# The layout follows Martin Wimpus' nix-config (github.com/wimpysworld/nix-config,
# Blue Oak Model License 1.0.0), which is also where ../ai/ccstatusline.nix
# comes from. Their herdr module is config.toml plus a worktree wrapper and
# manages no plugins, so ./plugins.nix has no upstream precedent to copy and
# instead follows the rule ../ai/default.nix already states for Claude Code
# plugins: load from the store, never from a client's own installer.
{
  inputs,
  lib,
  local,
  pkgs,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) system;

  herdr = inputs.herdr.packages.${system}.default;
  herdrBin = lib.getExe herdr;

  tomlFormat = pkgs.formats.toml { };

  plugins = import ./plugins.nix { inherit lib pkgs; };

  # Plugin id -> store path. The ids are upstream's, read from each
  # herdr-plugin.toml, and are what `herdr plugin list` reports; they do not
  # all match the attribute names, so they cannot be derived from them.
  pluginRoots = {
    "herdr-file-viewer" = plugins.herdr-file-viewer;
    "persiyanov.reviewr" = plugins.herdr-reviewr;
    "cloudmanic.herdr-plus" = plugins.herdr-plus;
    "herdr-navigator" = plugins.herdr-navigator;
    "herdr-spreader" = plugins.herdr-spreader;
    "jt.command-palette" = plugins.herdr-command-palette;
  };

  # The desired set as `<id>\t<store path>` lines, sorted, so activation can
  # compare it against the live set with a plain string equality.
  desiredPlugins = pkgs.writeText "herdr-desired-plugins" (
    lib.concatStringsSep "\n" (
      lib.sort (a: b: a < b) (lib.mapAttrsToList (id: root: "${id}\t${root}") pluginRoots)
    )
    + "\n"
  );

  # Decides whether a hand-written config.toml can be discarded: true only when
  # every leaf it sets is also set, to the same value, in the declared file.
  # Comparing parsed TOML rather than bytes means formatting, key order, and
  # section style never make a safe file look unsafe.
  configIsSubset = pkgs.writeText "herdr-config-is-subset.py" ''
    import sys, tomllib


    def leaves(table, prefix=()):
        for key, value in table.items():
            path = prefix + (key,)
            if isinstance(value, dict):
                yield from leaves(value, path)
            else:
                yield path, value


    with open(sys.argv[1], "rb") as handle:
        live = tomllib.load(handle)
    with open(sys.argv[2], "rb") as handle:
        declared = dict(leaves(tomllib.load(handle)))

    sys.exit(0 if all(declared.get(p, object()) == v for p, v in leaves(live)) else 1)
  '';

  herdrConfigToml = tomlFormat.generate "herdr-config.toml" settings;

  settings = {
    # Herdr shows onboarding until it writes `onboarding = false` back into
    # this file. Nix renders it as a read-only store symlink, so Herdr can
    # never record completion itself and would ask on every start. Pre-setting
    # the flag is the same workaround Wimpy's module documents.
    onboarding = false;

    theme.name = "catppuccin";

    ui = {
      show_agent_labels_on_pane_borders = true;
      toast.delivery = "herdr";
    };

    # Plugin actions are otherwise unreachable from the UI, so each one worth
    # a muscle-memory key gets one, and the palette covers everything else —
    # including any plugin added later, with no change here.
    #
    # Every key below is checked free against `herdr --default-config`. Note
    # `prefix+d` is safe: the default binds close_workspace to prefix+shift+d,
    # not to plain d. Rebinding a default is a different decision from filling
    # a gap in it, and this file only does the latter.
    keys.command = [
      {
        key = "prefix+space";
        type = "plugin_action";
        command = "jt.command-palette.open";
        description = "command palette (every plugin action)";
      }
      {
        key = "prefix+f";
        type = "plugin_action";
        command = "herdr-file-viewer.open-file-viewer";
        description = "file viewer";
      }
      {
        key = "prefix+d";
        type = "plugin_action";
        command = "persiyanov.reviewr.toggle";
        description = "review agent diff";
      }
      {
        key = "prefix+m";
        type = "plugin_action";
        command = "herdr-navigator.open";
        description = "navigator";
      }
      {
        key = "prefix+a";
        type = "plugin_action";
        command = "cloudmanic.herdr-plus.quick-actions";
        description = "quick actions";
      }
      {
        key = "prefix+shift+o";
        type = "plugin_action";
        command = "cloudmanic.herdr-plus.projects";
        description = "projects";
      }
      {
        key = "prefix+shift+a";
        type = "plugin_action";
        command = "herdr-spreader.apply";
        description = "apply workspace layout";
      }
    ];
  };

  # One workspace per declared project, each with a shell and a `git status`
  # split beneath it.
  #
  # Derived from local.projects rather than written out here, for two reasons.
  # It is the only place project paths are allowed to live — AGENTS.md forbids
  # committing a private repository's name or path, and
  # scripts/check-private-names.sh enforces that from a denylist built out of
  # exactly this attrset. And it means the layout describes whatever this
  # machine actually has, with no second list to fall out of step.
  #
  # Deliberately no agent panes. `apply` builds every workspace at once, so a
  # `claude` command here would launch one agent per project on a single
  # keypress. Start them yourself in the workspace you want.
  spreaderLayout = (pkgs.formats.yaml { }).generate "herdr-spreader-layout.yaml" {
    workspaces = lib.mapAttrsToList (name: root: {
      inherit name root;
      tabs = [
        {
          label = "shell";
          panes = [
            { }
            {
              split = "down";
              ratio = 0.3;
              command = "git status";
            }
          ];
        }
      ];
    }) (local.projects or { });
  };
in
{
  # Herdr reads this at startup and on `herdr server reload-config`. A store
  # symlink is correct for the same reason it is for ccstatusline's settings:
  # the tool reads this file, and only its own interactive configurator writes
  # it. The cost is real and accepted — `herdr config reset-keys` and any
  # in-app preference change cannot persist. Change preferences here instead.
  xdg.configFile."herdr/config.toml".source = herdrConfigToml;

  # A hand-written config.toml already exists on this machine, and Home Manager
  # refuses to replace an unmanaged file — correctly, per AGENTS.md. Clear it,
  # but ONLY on evidence that nothing is lost: every key it sets must also be
  # declared above with the same value. A file holding anything else is left
  # alone and activation fails on the collision, which is the right outcome —
  # someone configured something here that this module does not know about.
  #
  # This depends on `checkLinkTargets` BY NAME for the reason
  # ../ai/default.nix documents for the same pattern: checkLinkTargets is
  # itself entryBefore writeBoundary, so declaring this the same way puts both
  # in one DAG tier with no ordering between them.
  home.activation.claimHerdrConfig = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
    liveConfig="''${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml"

    if [[ -f "$liveConfig" && ! -L "$liveConfig" ]]; then
      if ${lib.getExe pkgs.python3} ${configIsSubset} "$liveConfig" ${herdrConfigToml}; then
        run rm -f "$liveConfig"
      else
        warnEcho "Leaving hand-written Herdr config in place: $liveConfig"
        warnEcho "It sets something modules/home/herdr/default.nix does not declare."
        warnEcho "Fold those settings into that module, then rebuild."
      fi
    fi
  '';

  # herdr-spreader's workspace layout.
  #
  # It searches $HERDR_PLUGIN_CONFIG_DIR/config.yaml first and this path
  # second. The plugin config directory is Herdr-provisioned mutable state, so
  # the layout goes here instead, where Home Manager can own it — and a file
  # written into the plugin directory by hand would silently take precedence.
  #
  # Only nix-config is described. AGENTS.md forbids committing the name of a
  # private repository, and scripts/check-private-names.sh enforces it from a
  # denylist derived from local.nix, so a layout naming the work repositories
  # cannot live in this file. Adding those means rendering the workspace list
  # from local.nix at build time, the way scripts/rebuild.sh reads the backup
  # vault — a separate change, deliberately not smuggled into this one.
  xdg.configFile."herdr-spreader/config.yaml".source = spreaderLayout;

  # Reconcile the linked plugin set against the declared one.
  #
  # `herdr plugin link` writes into Herdr's own registry, which is mutable
  # state this repository cannot render as a file — so this is an activation
  # step rather than a symlink. What it links is still purely declarative: each
  # root is a store path built by ./plugins.nix, and the ids and paths come
  # from `desiredPlugins`, not from whatever happens to be installed.
  #
  # Gated on a real difference, per AGENTS.md: activation runs on every
  # rebuild, and relinking unconditionally would restart plugin panes during
  # rebuilds that have nothing to do with Herdr.
  home.activation.linkHerdrPlugins = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    # No server means no registry to reconcile. This is normal — Herdr is not
    # running on a freshly booted machine, and it reads the declared set when
    # it next starts.
    if [[ ! -S "''${XDG_CONFIG_HOME:-$HOME/.config}/herdr/herdr.sock" ]]; then
      verboseEcho "Herdr is not running; skipping plugin reconciliation"
    else
      # `plugin list` emits one JSON envelope; pull id and root back out as the
      # same tab-separated, sorted shape as the desired file.
      #
      # A FAILED call is not an empty registry, and conflating the two is what
      # broke activation on 2026-08-21. Upgrading Herdr leaves a new CLI talking
      # to the still-running old server, which answers every command with
      # {"error":{"code":"protocol_mismatch"}}. The old code sent that down the
      # `|| livePlugins=""` path, concluded that nothing was linked, and went on
      # to relink the whole declared set against a server that could not accept
      # a single one of them — so `plugin link` failed, and because it was
      # unguarded it aborted the entire Home Manager activation. Everything
      # ordered after this entry silently never ran, including setupLaunchAgents,
      # while darwin-rebuild still exited 0.
      #
      # So the envelope is inspected rather than assumed: `.result.plugins` must
      # actually be present before any reconciliation happens.
      if ! pluginRegistry="$(${herdrBin} plugin list --json 2>/dev/null)" \
        || ! printf '%s' "$pluginRegistry" \
             | ${lib.getExe pkgs.jq} -e 'has("result") and (.result | has("plugins"))' >/dev/null 2>&1; then
        # A BRANCH, not an early return. Home Manager concatenates every
        # activation snippet into one script body rather than into functions,
        # so `return` here is "can only return from a function or sourced
        # script" — which would abort activation exactly like the failure this
        # guard exists to prevent.
        warnEcho "Herdr's CLI could not read the plugin registry; skipping plugin reconciliation. If Herdr was just upgraded, the running server is older than the CLI — run 'herdr server stop' (this exits pane processes) and rebuild."
      else
          livePlugins="$(
          printf '%s' "$pluginRegistry" \
            | ${lib.getExe pkgs.jq} -r '.result.plugins[]? | "\(.plugin_id)\t\(.plugin_root)"' \
            | sort
        )"

        if [[ "$livePlugins" == "$(cat ${desiredPlugins})" ]]; then
          verboseEcho "Herdr plugins are already current"
        else
          # Unlink anything whose id is declared but whose root has moved, and
          # anything not declared at all. Plugins installed outside this
          # repository are left alone: this removes only ids it owns.
          while IFS=$'\t' read -r liveId liveRoot; do
            [[ -n "$liveId" ]] || continue
            if ! grep -qF "$liveId	$liveRoot" ${desiredPlugins} \
              && grep -qF "$liveId	" ${desiredPlugins}; then
              run ${herdrBin} plugin unlink "$liveId" \
                || warnEcho "Herdr refused to unlink $liveId; leaving the registry alone"
            fi
          done <<< "$livePlugins"

          while IFS=$'\t' read -r wantId wantRoot; do
            [[ -n "$wantId" ]] || continue
            if ! printf '%s\n' "$livePlugins" | grep -qF "$wantId	$wantRoot"; then
              run ${herdrBin} plugin link "$wantRoot" \
                || warnEcho "Herdr refused to link $wantRoot; leaving the registry alone"
            fi
          done < ${desiredPlugins}
        fi

        # config.toml is a symlink whose target changes when `settings` above
        # changes; the running server holds the old contents until told.
        run ${herdrBin} server reload-config || \
          warnEcho "Herdr is running but refused reload-config; restart it to pick up config.toml"
      fi
    fi
  '';
}
