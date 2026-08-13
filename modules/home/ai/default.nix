{
  ai,
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    listToAttrs
    mapAttrs
    mapAttrs'
    mkEnableOption
    mkIf
    nameValuePair
    ;

  # Matt Pocock's skills, from the pinned flake input.
  #
  # Claude Code loads the whole tree as a plugin, which namespaces every skill
  # as `mattpocock:<name>` and so cannot collide with a built-in or with a
  # project's own skills.
  #
  # Codex is given the same skills as plain skill directories instead. Not
  # because Codex lacks plugins — it has them, with `.codex-plugin/plugin.json`
  # manifests, marketplaces, and `[plugins."<name>@<marketplace>"]` entries in
  # ~/.codex/config.toml — but because the two plugin formats are different and
  # this upstream ships only the Claude Code manifest. There is no Codex plugin
  # here to install.
  #
  # What both clients do share is the portable `SKILL.md` layout, so the same
  # input serves both, composed into each client's native form rather than
  # vendored twice.
  mattPocockSkills = inputs.mattpocock-skills;

  # The plugin manifest is the authoritative list; deriving it here means a
  # skill added or removed upstream is picked up by a lock update alone.
  mattPocockManifest = builtins.fromJSON (
    builtins.readFile "${mattPocockSkills}/.claude-plugin/plugin.json"
  );

  # Prefixed for Codex to mirror the namespacing Claude Code gets for free from
  # the plugin. Without it, upstream's `research` would land on the same path as
  # this repository's own `research` agent.
  mattPocockCodexSkills = listToAttrs (
    map (
      relativePath:
      let
        path = lib.removePrefix "./" relativePath;
        skillName = baseNameOf path;
      in
      nameValuePair ".codex/skills/mattpocock-${skillName}" {
        source = "${mattPocockSkills}/${path}";
        recursive = true;
      }
    ) mattPocockManifest.skills
  );

  codexSkill =
    name: agent:
    pkgs.writeText "codex-skill-${name}.md" ''
      ---
      name: ${name}
      description: ${agent.description}
      ---

      ${builtins.readFile agent.prompt}
    '';

  # Rendered as text rather than a store path, because the upstream
  # `programs.claude-code.agents` option takes either and text keeps the whole
  # agent visible in a single generated file.
  claudeAgentText = name: agent: ''
    ---
    name: ${name}
    description: ${agent.description}
    ---

    ${builtins.readFile agent.prompt}
  '';

  codexServers = mapAttrs (
    _name: server:
    {
      inherit (server) url;
    }
    // lib.optionalAttrs (server ? bearerTokenEnvVar) {
      bearer_token_env_var = server.bearerTokenEnvVar;
    }
  ) ai.mcpServers;

  codexToml = (pkgs.formats.toml { }).generate "codex-config.toml" {
    mcp_servers = codexServers;
  };

  mcpRegistryJson = pkgs.writeText "ai-mcp-registry.json" (
    builtins.toJSON {
      schemaVersion = 1;
      servers = ai.mcpServers;
    }
  );

  codexSkillFiles = mapAttrs' (
    name: agent:
    nameValuePair ".codex/skills/${name}/SKILL.md" {
      source = codexSkill name agent;
    }
  ) ai.agents;

  # Claude Code's user-scoped settings. This is desired configuration, so it is
  # declared here rather than left as whatever the client last wrote — the whole
  # point being that an agent, or anything else, can delete ~/.claude and
  # `darwin-rebuild switch` puts it back.
  #
  # Deliberately NOT `programs.claude-code.settings`, which is the one part of
  # that module this configuration does not use. It writes settings.json as a
  # read-only Nix store symlink, and Claude Code writes to that file itself when
  # settings change through its own interface. Pointing an application's
  # writable configuration file at the store is the failure this repository has
  # already paid for once — see the comment at the top of ../mouse.nix — so the
  # file is installed real and reasserted instead, exactly as karabiner.nix and
  # mouse.nix do for applications that own their configuration at runtime.
  #
  # The consequence is deliberate and worth knowing: values changed at runtime
  # are reverted at the next activation, and keys not declared here are dropped.
  # Change them in this file instead.
  claudeSettings = {
    skipDangerousModePermissionPrompt = true;
    theme = "dark";
    tui = "fullscreen";

    # The guard is referenced by absolute Nix store path and run with an
    # explicit interpreter. Nothing under ~/.claude is involved, so removing
    # that directory cannot silently disable the rule the hook enforces.
    hooks.PreToolUse = [
      {
        matcher = "Bash";
        hooks = [
          {
            type = "command";
            command = "${pkgs.python3}/bin/python3 ${ai.hooks.nixOnlyGuard}";
            timeout = 10;
          }
        ];
      }
    ];
  };

  claudeSettingsJson = pkgs.writeText "claude-settings.json" (builtins.toJSON claudeSettings);
in
{
  options.nixConfig.ai.enable = mkEnableOption "shared Codex and Claude Code configuration";

  config = mkIf config.nixConfig.ai.enable {
    # Claude Code's own Home Manager module owns the client's instruction file
    # and agent definitions. Prefer it over hand-rolled `home.file` entries: it
    # is maintained upstream, understands this client's layout, and already
    # covers commands, skills, rules, output styles, plugins, and marketplaces
    # when those are wanted later.
    programs.claude-code = {
      enable = true;

      # The module owns the package because `plugins` works by wrapping it with
      # `--plugin-dir`. development.nix therefore does NOT install claude-code;
      # only one of them may, or they collide on bin/claude.
      package = config.nixConfig.claudeCode.package;

      # Loaded straight from the Nix store. `claude plugins install` would
      # write mutable state under ~/.claude that this repository could not
      # restore, which is the whole thing this configuration exists to avoid.
      plugins = [ mattPocockSkills ];

      context = ai.instructions;
      agents = mapAttrs claudeAgentText ai.agents;
    };

    # Both would install an executable named `claude`. The 1Password launcher
    # is currently disabled, so this cannot fire today; it exists so that
    # enabling it fails with an explanation rather than an opaque collision.
    assertions = [
      {
        assertion = !config.nixConfig.secrets.onePassword.enable;
        message = ''
          Both programs.claude-code and the 1Password launcher would provide
          bin/claude. Point the launcher at
          config.programs.claude-code.finalPackage — which carries the plugin
          wrapper — and set programs.claude-code.package to null.
        '';
      }
    ];

    # Instructions and agent definitions are linked from the store. Nothing
    # writes to them at runtime, so a read-only symlink is correct here: it
    # cannot drift, and Home Manager restores it if it is removed.
    home.file =
      codexSkillFiles
      // mattPocockCodexSkills
      // {
        ".codex/AGENTS.md".source = ai.instructions;
        # Codex mutates ~/.codex/config.toml at runtime. Keep the declarative
        # desired state as a reviewable artifact instead of replacing the live
        # file with an immutable Nix-store symlink.
        ".config/nix-config/ai/codex-config.toml".source = codexToml;
        ".config/nix-config/ai/mcp-registry.json".source = mcpRegistryJson;
      };

    # Codex creates an empty ~/.codex/AGENTS.md on first run. Home Manager
    # refuses to replace an unmanaged file, so activation would abort before
    # writing anything. Clear that placeholder, but ONLY on evidence that it is
    # empty — if it has content, someone wrote instructions there by hand and
    # this configuration must not silently discard them.
    #
    # This depends on `checkLinkTargets` BY NAME, not merely on `writeBoundary`.
    # checkLinkTargets is itself declared entryBefore [ "writeBoundary" ], so
    # declaring this the same way puts both in one DAG tier with no ordering
    # between them — and on 2026-08-13 the check ran first and aborted
    # activation on the very file this entry exists to clear.
    home.activation.clearEmptyCodexInstructions = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
      codexInstructions="$HOME/.codex/AGENTS.md"

      if [[ -f "$codexInstructions" && ! -L "$codexInstructions" ]]; then
        if [[ -s "$codexInstructions" ]]; then
          errorEcho "Refusing to replace non-empty unmanaged file: $codexInstructions"
          errorEcho "Move its contents into ai/instructions/global.md, then remove it."
          exit 1
        fi

        run rm -f "$codexInstructions"
      fi
    '';

    # Before this configuration existed, the guard was a loose file at
    # ~/.claude/hooks/nix-only-guard.py and settings.json referenced it there.
    # It is now committed and referenced by store path, leaving that copy
    # orphaned — unreferenced, unmanaged, and misleading to anyone who finds it,
    # since editing it would change nothing. Remove it, but only on evidence
    # that it is byte-identical to the committed script; if it differs, someone
    # made local changes that are not in this repository and should not be
    # silently discarded.
    home.activation.removeLegacyClaudeGuardHook = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      legacyGuard="$HOME/.claude/hooks/nix-only-guard.py"

      if [[ -f "$legacyGuard" && ! -L "$legacyGuard" ]]; then
        if /usr/bin/cmp -s ${ai.hooks.nixOnlyGuard} "$legacyGuard"; then
          run rm -f "$legacyGuard"
          # Only if nothing else lives there; rmdir refuses a non-empty
          # directory, which is exactly the check wanted.
          rmdir "$HOME/.claude/hooks" 2>/dev/null || true
        else
          warnEcho "Leaving modified legacy hook in place: $legacyGuard"
          warnEcho "It is no longer referenced. Fold any changes into ai/hooks/nix-only-guard.py."
        fi
      fi
    '';

    # settings.json cannot be a store symlink for two independent reasons:
    # Claude Code writes to it at runtime, and a real unmanaged copy already
    # exists on this machine, which Home Manager's collision check would refuse
    # to replace. So install a real file and reassert it, the same arrangement
    # karabiner.nix and mouse.nix use for applications that own their own
    # configuration file at runtime.
    home.activation.installClaudeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      claudeDirectory="$HOME/.claude"

      # An older generation may have linked this into the store.
      if [[ -L "$claudeDirectory/settings.json" ]]; then
        run rm -f "$claudeDirectory/settings.json"
      fi

      run mkdir -p "$claudeDirectory"

      # Only rewrite on a real difference, so an unrelated activation does not
      # touch the file the client is reading.
      if /usr/bin/cmp -s ${claudeSettingsJson} "$claudeDirectory/settings.json"; then
        verboseEcho "Claude Code settings are already current"
      else
        run /usr/bin/install -m 0644 ${claudeSettingsJson} \
          "$claudeDirectory/settings.json"
      fi
    '';
  };
}
