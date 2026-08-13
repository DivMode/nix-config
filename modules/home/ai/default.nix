{
  ai,
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mapAttrs
    mapAttrs'
    mkEnableOption
    mkIf
    nameValuePair
    ;

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

      # Configuration only. The package itself is installed by
      # development.nix, which also decides whether the unwrapped binary or the
      # 1Password launcher provides `claude`. Declaring it here as well would
      # install it twice and collide on bin/claude.
      package = null;

      context = ai.instructions;
      agents = mapAttrs claudeAgentText ai.agents;
    };

    # Instructions and agent definitions are linked from the store. Nothing
    # writes to them at runtime, so a read-only symlink is correct here: it
    # cannot drift, and Home Manager restores it if it is removed.
    home.file = codexSkillFiles // {
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
