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

  mcpServers = import ./mcp/servers.nix;
}
