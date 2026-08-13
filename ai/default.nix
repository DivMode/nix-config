{
  instructions = ./instructions/global.md;

  agents = {
    implementation = {
      description = "Implement a bounded change and verify it without expanding scope.";
      prompt = ./agents/implementation/prompt.md;
    };

    research = {
      description = "Investigate a technical question using primary sources and report evidence.";
      prompt = ./agents/research/prompt.md;
    };
  };

  # Client hook programs. These are declared here, rather than written into a
  # client's own directory, so that losing or wiping that directory cannot
  # disarm them: the renderer points each client at the Nix store path.
  hooks = {
    nixOnlyGuard = ./hooks/nix-only-guard.py;
  };

  mcpServers = import ./mcp/servers.nix;
}
