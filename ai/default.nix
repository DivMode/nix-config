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
    # Hands work to a fresh agent in a new Herdr pane: reconcile live sessions,
    # checkpoint durably, write the handoff, transfer scheduled jobs, start it.
    session-handoff = ./skills/session-handoff;
    # End-of-work review in one pass: confirm merged/deployed/observed, then
    # product, agent-environment and architecture lenses (the latter two adapted
    # from Matt Pocock's user-invoked retro and improve-codebase-architecture,
    # which a skill cannot start); the agent decides each finding (fix, file or drop) and reports.
    wrap-up = ./skills/wrap-up;
    # Storing and reading credentials through the Connect server: the item
    # write command, the 0600 file convention, and which commands may touch
    # 1Password at all.
    onepassword = ./skills/onepassword;
  };

  # This repository's own skills for Claude Code only, because they drive a
  # tool Codex does not have. Linked under ~/.claude/skills beside the shared
  # ones above.
  claudeSkills = {
    # Delegation to Claude sub-agents through the Agent tool. The sibling of
    # codexOrchestrator.delegateSkill; the global Roles rule picks between the
    # two by the user's words.
    opus-delegate = ./claude-skills/opus-delegate;
  };

  # The worker brief both delegation skills write from. modules/home/ai puts a
  # copy beside each skill's SKILL.md, so the two skills cannot drift apart.
  delegationAssignment = ./delegation/assignment.md;

  # Local additions to the codex-orchestrator Claude Code plugin: the
  # delegation policy skill, the post-run scope check, and the journal writer. Claude
  # Code only; modules/home/ai layers them into the plugin tree.
  codexOrchestrator = {
    delegateSkill = ./codex-orchestrator/codex-delegate;
    scopeCheck = ./codex-orchestrator/codex-scope.sh;
    journal = ./codex-orchestrator/codex-journal.sh;
    journalTest = ./codex-orchestrator/codex-journal-test.sh;
  };

  # The signal guard for every shell an agent client starts (issue #270): in
  # those shells `kill` refuses a process group the shell did not start, and
  # the pattern-based terminators are refused. `environment` is what each
  # client sets for the commands it runs: the marker that turns the guard on,
  # and BASH_ENV, which every non-interactive bash sources. zsh has no such
  # variable, so modules/home/ai sources `killGuard` from ZDOTDIR's .zshenv
  # when the marker is set.
  #
  # The rest reaches what neither startup file does (issue #270, follow-up):
  #   - AGENT_KILL_GUARD_BIN is ./shell-guard/bin, which the guard puts first
  #     on PATH: `kill`, `pkill` and `killall` as programs, for `xargs`, make
  #     and other programs that run them without a shell.
  #   - The BASH_FUNC_ variables are exported bash functions, which every bash
  #     imports, `sh` included (on macOS /bin/sh is bash in POSIX mode, which
  #     reads no BASH_ENV). Each loads the guard and runs its function of the
  #     same name: an `sh` started below a zsh (make, npm scripts, Python's
  #     `shell=True`) otherwise has no guard, because zsh cannot export a
  #     function. A bash exports the full functions itself.
  shellGuard = rec {
    directory = ./shell-guard;
    killGuard = "${directory}/kill-guard.sh";
    killGuardTest = "${directory}/kill-guard-test.sh";
    environment = {
      AGENT_KILL_GUARD = "1";
      AGENT_KILL_GUARD_BIN = "${directory}/bin";
      BASH_ENV = killGuard;
    }
    // builtins.listToAttrs (
      map (name: {
        name = "BASH_FUNC_${name}%%";
        # A loader whose guard is gone (a store path collected under a session
        # older than the garbage collector's window) refuses and says so: a
        # failed `.` would end the whole `sh`. Only the probe of one process
        # id still runs, so a script that waits on its child does not hang.
        value = "() { if [ -r ${killGuard} ]; then AGENT_KILL_GUARD=1; . ${killGuard} && ${name} \"$@\"; elif [ ${name} = kill ] && [ $# = 2 ] && [ \"$1\" = -0 ] && [ -n \"\${2##*[!0-9]*}\" ]; then builtin kill -0 \"$2\"; else echo \"kill guard: ${killGuard} is gone; start a new session\" >&2; return 1; fi; }";
      }) loaded
    );
    # The names each loader is for.
    loaded = [
      "kill"
      "pkill"
      "killall"
    ];
  };

  # Machine-only hook declarations and their build contract. Neither client
  # loads hooks from user settings, repositories, or delegation command lines.
  hooks = ./hooks;

  mcpServers = import ./mcp/servers.nix;
}
