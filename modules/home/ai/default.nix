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
    concatMapStringsSep
    elem
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

  # Grafana's official Claude Code plugin for the gcx CLI — skills for
  # querying dashboards, metrics, logs and alerts, plus a `grafana-debugger`
  # agent. Upstream documents installation through its plugin marketplace
  # (`/plugin marketplace add grafana/gcx`), which writes mutable state under
  # ~/.claude; loaded from the pinned source tree instead, for the same
  # reason as Matt Pocock's skills above.
  #
  # The plugin lives in a subdirectory: the repository root is the Go module
  # that builds the CLI itself. development.nix builds the binary from the
  # SAME input, so the skills and the CLI they drive cannot drift apart
  # across an update.
  #
  # Skills excluded from both clients. Checked 2026-08-16 against the live
  # stack, not guessed: the SLO product has zero definitions, IRM/OnCall has
  # zero schedules and zero integrations, there is no LLM product to
  # instrument with Agent Observability, no Entity Graph workflow, and
  # Grafana resources are managed from the work monorepo's own
  # infrastructure code, not a gcx-scaffolded Go project. Demo and
  # from-scratch-onboarding tours round out the list. Every bundled skill's
  # description is injected into every session's context (~3.8k tokens for
  # all 24 skills, ~2.5k of it these), so an unused skill is paid for on
  # every prompt. A listed name that later vanishes upstream is a harmless
  # no-op; a product adopted later (an SLO defined, OnCall wired up) means
  # deleting its names from this list.
  gcxSkillsExcluded = [
    "agento11y"
    "agento11y-instrument"
    "agento11y-prod-setup"
    "agento11y-test-starter"
    "diagnose-entity-graph"
    "gcx-demo"
    "gcx-observability"
    "generate-resource-stubs"
    "import-dashboards"
    "oncall-triage"
    "scaffold-project"
    "slo-check-status"
    "slo-investigate"
    "slo-manage"
    "slo-optimize"
  ];

  gcxClaudePlugin = pkgs.runCommand "gcx-claude-plugin" { } ''
    cp -r ${inputs.gcx-src}/claude-plugin $out
    chmod -R u+w $out
    ${concatMapStringsSep "\n" (name: "rm -rf $out/skills/${name}") gcxSkillsExcluded}
  '';

  # The same gcx skills for Codex. Upstream's official cross-agent path is
  # `gcx agent skills install --all`, which copies this identical bundle (the
  # binary embeds claude-plugin/skills/, its canonical source) into
  # ~/.agents/skills as mutable un-restorable state — so it is composed from
  # the store instead, exactly like Matt Pocock's skills below.
  #
  # Enumerated by reading the skills directory rather than a manifest, because
  # the gcx plugin manifest does not list its skills; a skill added or removed
  # upstream is picked up by moving the tag pin alone. Prefixed to mirror the
  # `gcx:` namespacing Claude Code gets for free from the plugin.
  gcxCodexSkills =
    mapAttrs'
      (
        name: _type:
        nameValuePair ".codex/skills/gcx-${name}" {
          source = "${inputs.gcx-src}/claude-plugin/skills/${name}";
          recursive = true;
        }
      )
      (
        lib.filterAttrs (name: type: type == "directory" && !(elem name gcxSkillsExcluded)) (
          builtins.readDir "${inputs.gcx-src}/claude-plugin/skills"
        )
      );

  # Status line packages, segment layout, and the two helper scripts.
  ccstatusline = import ./ccstatusline.nix { inherit inputs lib pkgs; };

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

  # Codex owns config.toml as mutable application state. This packages the
  # comment-preserving merger and the narrow preference document it overlays;
  # the live file remains a normal writable file rather than a store symlink.
  codexConfig = import ../../../ai/codex { inherit pkgs; };

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

  # This repository's own shared skills, in Codex's layout. Claude Code gets
  # the same directories through `programs.claude-code.skills` below, which
  # takes a directory path and links the whole tree.
  #
  # `recursive` matters: without it Home Manager symlinks the directory itself,
  # and a client that resolves a skill's supporting files relative to a real
  # directory sees a store path instead. Linking the entries individually keeps
  # the tree shaped the way each client expects.
  sharedCodexSkills = mapAttrs' (
    name: path:
    nameValuePair ".codex/skills/${name}" {
      source = path;
      recursive = true;
    }
  ) ai.skills;

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
  # Values changed at runtime are reverted at the next activation. Keys the
  # client writes that Nix does not declare are kept; see installClaudeSettings.
  claudeSettings = {
    skipDangerousModePermissionPrompt = true;
    theme = "dark";
    tui = "fullscreen";

    # ccstatusline formats the status bar. Claude Code reads this key on
    # startup and invokes the command once per render. See ./ccstatusline.nix.
    statusLine = ccstatusline.statusLine;

    # Every session starts with permission prompts off. The nix-only-guard
    # PreToolUse hook below still runs and still denies under this mode, so the
    # machine boundary is unaffected; what bypassing removes is the prompts.
    # It does not protect against prompt injection — the guard does.
    permissions.defaultMode = "bypassPermissions";

    # Bash runs unsandboxed, matching how this machine is actually worked.
    #
    # This is the LOWEST-precedence settings file. Claude Code resolves scopes
    # managed > command line > project `.claude/settings.local.json` > project
    # `.claude/settings.json` > this one, so any repository declaring its own
    # `sandbox` block overrides what is set here. Setting it globally is
    # therefore a default, not a guarantee; a project that wants this posture
    # must leave the key unset rather than restate it, or the two drift.
    #
    # `autoAllowBashIfSandboxed` only has meaning while the sandbox is on — it
    # skips the approval prompt for commands the sandbox already contains — so
    # it is declared false alongside for consistency rather than effect.
    sandbox = {
      enabled = false;
      autoAllowBashIfSandboxed = false;
    };

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

    # Herdr's sidebar draws each agent's running/waiting/idle state from this.
    # `herdr integration install claude` writes the same registration pointing
    # at a loose copy in ~/.claude/hooks/; pointing at the store path instead
    # means wiping ~/.claude cannot disarm it, exactly as for the guard above.
    #
    # The cost is that `herdr integration status` reports `claude: not
    # installed`, because it tests for its own file path rather than reading
    # this registration. That report is wrong about the behaviour: running this
    # store copy with a SessionStart payload was verified to set the pane's
    # agent session through `pane.report_agent_session`, which is the whole job
    # of the hook. Do not "fix" the status line by running `herdr integration
    # install claude` — that rewrites this key to the loose path, which the
    # next activation reverts, and reintroduces the undeclared file.
    hooks.SessionStart = [
      {
        matcher = "*";
        hooks = [
          {
            type = "command";
            command = "${lib.getExe pkgs.bash} ${ai.hooks.herdrAgentState} session";
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
      plugins = [
        mattPocockSkills
        gcxClaudePlugin
      ];

      context = ai.instructions;
      agents = mapAttrs claudeAgentText ai.agents;

      # Directory paths, which the module links as whole trees under
      # ~/.claude/skills/<name>/ — so a skill that grows references/ or
      # rules/ beside its SKILL.md needs no change here.
      skills = ai.skills;
    };

    # Session launchers, declared beside the client they launch.
    #
    # The flag is not redundant with `permissions.defaultMode` above. Settings
    # precedence is managed > command line > project > this user file, which is
    # lowest, so a repository declaring its own mode overrides claudeSettings
    # but not this flag.
    #
    # `cc` shadows the C compiler at /usr/bin/cc in INTERACTIVE shells only —
    # aliases are not expanded by scripts, Makefiles, or build tools, so this
    # cannot affect a compile. It only means a hand-typed `cc foo.c` starts an
    # agent. Renaming this one attribute is the whole fix if that ever bites.
    programs.zsh.shellAliases = {
      cc = "claude --dangerously-skip-permissions";
      # Interactive session picker. `-r` with no value lists the conversations
      # for the current directory rather than resuming blindly.
      ccr = "claude --resume --dangerously-skip-permissions";
      # The most recent conversation in this directory, with no picker.
      ccc = "claude --continue --dangerously-skip-permissions";
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
      // gcxCodexSkills
      // sharedCodexSkills
      // {
        ".codex/AGENTS.md".source = ai.instructions;
        # MCP endpoints remain a review artifact. Codex's live config paths and
        # plugin state are application-owned and may include private metadata.
        ".config/nix-config/ai/codex-config.toml".source = codexToml;
        ".config/nix-config/ai/codex-managed-preferences.toml".source = codexConfig.preferencesToml;
        ".config/nix-config/ai/mcp-registry.json".source = mcpRegistryJson;
      };

    # config.toml mixes a small set of durable preferences with state Codex
    # writes itself: plugin and marketplace registrations, project trust,
    # generated MCP paths, timestamps, and desktop settings. Overlay only the
    # generic preference document above with tomlkit, which preserves unknown
    # keys, tables, comments, and ordering while updating values in place.
    #
    # The merger parses before writing, refuses a symlink or invalid TOML, and
    # commits changed bytes through a 0600 temporary file in the same directory
    # followed by atomic rename. Identical content is not rewritten; a matching
    # file with broader permissions is chmodded to 0600 without changing bytes.
    home.activation.installCodexPreferences = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      codexDirectory="$HOME/.codex"
      configFile="$codexDirectory/config.toml"

      run mkdir -p "$codexDirectory"
      run ${lib.getExe codexConfig.merger} --declared ${codexConfig.preferencesToml} "$configFile"
    '';

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
      # Each pair is a loose copy under ~/.claude/hooks and the committed file
      # that now replaces it. The guard was orphaned when it moved into this
      # repository; the Herdr hook was written by `herdr integration install
      # claude` and is orphaned by declaring the same registration against the
      # store path in claudeSettings above.
      removeOrphanedHook() {
        local loose="$1" committed="$2" source="$3"

        [[ -f "$loose" && ! -L "$loose" ]] || return 0

        if /usr/bin/cmp -s "$committed" "$loose"; then
          run rm -f "$loose"
        else
          warnEcho "Leaving modified legacy hook in place: $loose"
          warnEcho "It is no longer referenced. Fold any changes into $source."
        fi
      }

      removeOrphanedHook "$HOME/.claude/hooks/nix-only-guard.py" \
        ${ai.hooks.nixOnlyGuard} "ai/hooks/nix-only-guard.py"
      removeOrphanedHook "$HOME/.claude/hooks/herdr-agent-state.sh" \
        ${ai.hooks.herdrAgentState} "ai/hooks/herdr-agent-state.sh"

      # Only if nothing else lives there; rmdir refuses a non-empty directory,
      # which is exactly the check wanted.
      rmdir "$HOME/.claude/hooks" 2>/dev/null || true
    '';

    # settings.json cannot be a store symlink for two independent reasons:
    # Claude Code writes to it at runtime, and a real unmanaged copy already
    # exists on this machine, which Home Manager's collision check would refuse
    # to replace. So install a real file and reassert it, the same arrangement
    # karabiner.nix and mouse.nix use for applications that own their own
    # configuration file at runtime.
    # MERGE the declared keys into the live file rather than replacing it, so
    # keys Claude Code writes for itself survive activation.
    #
    # The tradeoff: deleting a key from `claudeSettings` no longer removes it
    # from the live file, because a merge cannot tell "Nix stopped declaring
    # this" from "the client wrote this". Remove it there once by hand too.
    home.activation.installClaudeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      claudeDirectory="$HOME/.claude"
      settingsFile="$claudeDirectory/settings.json"

      # An older generation may have linked this into the store. A symlink is
      # wrong here for the reason this whole entry exists: Claude Code writes
      # to this file, and the store is read-only.
      if [[ -L "$settingsFile" ]]; then
        run rm -f "$settingsFile"
      fi

      run mkdir -p "$claudeDirectory"

      # Unparseable or absent live file degrades to an empty object rather than
      # failing activation; the declared keys are then written on their own.
      claudeCurrent="$(${lib.getExe pkgs.jq} --sort-keys '.' "$settingsFile" 2>/dev/null || echo '{}')"
      claudeMerged="$(
        printf '%s' "$claudeCurrent" \
          | ${lib.getExe pkgs.jq} --sort-keys --slurpfile declared ${claudeSettingsJson} '. * $declared[0]'
      )"

      # Only rewrite on a real difference, so an unrelated activation does not
      # touch the file the client is reading. Both sides are sorted, so
      # key order alone never counts as a change.
      if [[ "$claudeCurrent" == "$claudeMerged" ]]; then
        verboseEcho "Claude Code settings are already current"
      else
        run mkdir -p "$claudeDirectory"
        printf '%s\n' "$claudeMerged" > "$settingsFile.nix-config.tmp"
        run chmod 0644 "$settingsFile.nix-config.tmp"
        run mv "$settingsFile.nix-config.tmp" "$settingsFile"
      fi
    '';

    # ccstatusline's own configuration. A symlink is correct here: the tool
    # reads this file, and only its interactive TUI configurator writes it.
    # Reconfigure in ./ccstatusline.nix rather than through that TUI, which
    # would fail against a read-only store path.
    xdg.configFile."ccstatusline/settings.json".text = builtins.toJSON ccstatusline.settings;
  };
}
