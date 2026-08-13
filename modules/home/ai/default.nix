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

  claudeAgent =
    name: agent:
    pkgs.writeText "claude-agent-${name}.md" ''
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

  claudeAgentFiles = mapAttrs' (
    name: agent:
    nameValuePair ".claude/agents/${name}.md" {
      source = claudeAgent name agent;
    }
  ) ai.agents;
in
{
  options.nixConfig.ai.enable = mkEnableOption "shared Codex and Claude Code configuration";

  config = mkIf config.nixConfig.ai.enable {
    home.file =
      codexSkillFiles
      // claudeAgentFiles
      // {
        ".codex/AGENTS.md".source = ai.instructions;
        ".claude/CLAUDE.md".source = ai.instructions;
        # Codex mutates ~/.codex/config.toml at runtime. Keep the declarative
        # desired state as a reviewable artifact instead of replacing the live
        # file with an immutable Nix-store symlink.
        ".config/nix-config/ai/codex-config.toml".source = codexToml;
        ".config/nix-config/ai/mcp-registry.json".source = mcpRegistryJson;
      };
  };
}
