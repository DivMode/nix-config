{
  # The global instruction document, as a directory to be imported with `pkgs`.
  # It composes the two tracked sources under it — owner prose and the agent
  # orchestration policy — into the ONE document both clients are given, and
  # carries the checks that keep them in step. See ./instructions/default.nix.
  instructions = ./instructions;

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

  # Skill directories shared by every client. One canonical SKILL.md tree per
  # skill, composed into each client's native layout by the renderer rather
  # than vendored once per client — the arrangement Wimpy's nix-config uses for
  # its own skills.
  #
  # `herdr` is upstream's own skill, captured verbatim from `herdr --skill`. It
  # teaches an agent to drive panes, tabs, and workspaces through the socket
  # API, and gates itself on HERDR_ENV=1 so it stays inert outside a Herdr
  # pane. Refresh it by re-running that command when Herdr updates.
  skills = {
    herdr = ./skills/herdr;
  };

  # Client hook programs. These are declared here, rather than written into a
  # client's own directory, so that losing or wiping that directory cannot
  # disarm them: the renderer points each client at the Nix store path.
  hooks = {
    nixOnlyGuard = ./hooks/nix-only-guard.py;

    # Reports this agent's lifecycle state back to Herdr, which is what draws
    # the running/waiting/idle marks in its sidebar. Byte-identical to what
    # `herdr integration install claude` writes — verified by running that
    # command against a throwaway HOME and diffing — so this is upstream's own
    # artifact under version control, not a local edit of it.
    herdrAgentState = ./hooks/herdr-agent-state.sh;
  };

  mcpServers = import ./mcp/servers.nix;
}
