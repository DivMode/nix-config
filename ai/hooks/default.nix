# The only agent-hook declarations. Both managed client files are outputs of
# the contract derivation, so activation cannot install an unchecked policy.
{ pkgs, statusLine }:
let
  inherit (pkgs) lib;

  codexGuard = pkgs.writeShellApplication {
    name = "codex-guard";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = builtins.readFile ../codex-orchestrator/codex-guard.sh;
  };
  herdrAgentState = pkgs.writeShellApplication {
    name = "herdr-agent-state";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.python3
    ];
    text = ''
      exec ${lib.getExe pkgs.bash} ${./herdr-agent-state.sh} session
    '';
  };

  # One program judges typed commands and file edits (it picks the rule from
  # the tool's name) for both clients. Codex's copy passes `--client codex`,
  # which drops the two rules that exist only because Claude Code stops to ask
  # the owner about a script string or a substituting heredoc.
  nixOnlyGuard = [
    (lib.getExe pkgs.python3)
    "${./nix-only-guard.py}"
  ];
  nixOnlyGuardCodex = nixOnlyGuard ++ [
    "--client"
    "codex"
  ];

  # Probes for the signalling rule (issue #270): a typed process-group
  # signal, and a file edit that introduces one. A shell script is judged,
  # prose is not.
  groupSignal = "kill -TERM -- \"-$group\"";
  commandProbes = [
    {
      command = "brew install example";
      deny = true;
    }
    {
      command = groupSignal;
      deny = true;
    }
    {
      # The supervisor drops a denial longer than one pipe write (512 bytes),
      # so the reason for a very long command must still fit.
      command = "brew install " + lib.concatStrings (lib.genList (_: "some-cask ") 100);
      deny = true;
    }
    {
      command = "kill \"$pid\"";
      deny = false;
    }
  ];
  scratch = "/nonexistent/agent-hook-contract";

  declarations = [
    {
      name = "nix-only-guard";
      client = "claude";
      event = "PreToolUse";
      matcher = "Bash";
      kind = "deny";
      timeout = 10;
      argv = nixOnlyGuard;
      probes = commandProbes ++ [
        {
          command = "bash -c 'echo hi'";
          deny = true;
        }
      ];
    }
    {
      name = "signal-edit-guard";
      client = "claude";
      event = "PreToolUse";
      matcher = "Edit|Write|MultiEdit";
      kind = "deny";
      timeout = 10;
      argv = nixOnlyGuard;
      probes = [
        {
          label = "Write a shell script that signals a group";
          tool_name = "Write";
          tool_input = {
            file_path = "${scratch}/stop.sh";
            content = "${groupSignal}\n";
          };
          deny = true;
        }
        {
          label = "Edit a shell script to signal a group";
          tool_name = "Edit";
          tool_input = {
            file_path = "${scratch}/stop.sh";
            old_string = "echo done";
            new_string = groupSignal;
          };
          deny = true;
        }
        {
          label = "Write prose that names a group signal";
          tool_name = "Write";
          tool_input = {
            file_path = "${scratch}/notes.md";
            content = "${groupSignal}\n";
          };
          deny = false;
        }
      ];
    }
    # The same rules for Codex (issues #270 and #252). Its hook input was
    # measured, not assumed: on 2026-11-11 the codex-guard below let
    # `grep codex-guard-canary /dev/null` through (it skips a segment whose
    # first word is grep) and refused `echo codex-guard-canary` with
    # "Command: echo codex-guard-canary", so `tool_input.command` is the
    # command as written, not `/bin/zsh -lc …`. For file edits Codex's
    # apply_patch handler passes the patch text in the same field
    # (codex-rs/core/src/tools/handlers/apply_patch.rs:
    # `tool_input: serde_json::json!({ "command": command })`), and its hooks
    # documentation says such a hook matches as `apply_patch`.
    {
      name = "nix-only-guard-codex";
      client = "codex";
      event = "PreToolUse";
      matcher = "Bash";
      kind = "deny";
      timeout = 10;
      argv = nixOnlyGuardCodex;
      probes = commandProbes ++ [
        {
          command = "bash -c 'echo hi'";
          deny = false;
        }
      ];
    }
    {
      name = "signal-edit-guard-codex";
      client = "codex";
      event = "PreToolUse";
      matcher = "apply_patch";
      kind = "deny";
      timeout = 10;
      argv = nixOnlyGuardCodex;
      probes = [
        {
          label = "a patch adding a shell script that signals a group";
          tool_name = "apply_patch";
          tool_input.command = "*** Begin Patch\n*** Add File: ${scratch}/stop.sh\n+${groupSignal}\n*** End Patch\n";
          deny = true;
        }
        {
          label = "a patch adding prose that names a group signal";
          tool_name = "apply_patch";
          tool_input.command = "*** Begin Patch\n*** Add File: ${scratch}/notes.md\n+${groupSignal}\n*** End Patch\n";
          deny = false;
        }
      ];
    }
    {
      name = "herdr-agent-state";
      client = "claude";
      event = "SessionStart";
      matcher = "*";
      kind = "observe";
      timeout = 10;
      argv = [ (lib.getExe herdrAgentState) ];
      environments = [
        { }
        {
          HERDR_ENV = "1";
          HERDR_SOCKET_PATH = "/nonexistent/agent-hook-contract/socket";
          HERDR_PANE_ID = "contract";
        }
      ];
    }
    {
      name = "codex-guard";
      client = "codex";
      event = "PreToolUse";
      matcher = "Bash";
      kind = "deny";
      timeout = 10;
      argv = [ (lib.getExe codexGuard) ];
      environments = [
        { }
        { CODEX_ORCHESTRATOR_DELEGATED = "1"; }
      ];
      probes = [
        {
          command = "git push";
          environment.CODEX_ORCHESTRATOR_DELEGATED = "1";
          deny = true;
        }
        {
          command = "git push";
          deny = false;
        }
      ];
    }
  ];

  supervise =
    hook:
    hook
    // {
      supervised = true;
      argv = [
        (lib.getExe pkgs.python3)
        "${./.}/supervisor.py"
        "--kind"
        hook.kind
        "--timeout"
        (toString hook.timeout)
        "--"
      ]
      ++ hook.argv;
    };

  hooksFor =
    client: handlers:
    lib.mapAttrs (
      _event: hooks:
      map (hook: {
        inherit (hook) matcher;
        hooks = [
          {
            type = "command";
            inherit (hook) command timeout;
          }
        ];
      }) hooks
    ) (lib.groupBy (hook: hook.event) (builtins.filter (hook: hook.client == client) handlers));

  contract =
    name: declared:
    let
      # Shell-quote the same argv the contract executes. A shell fragment must
      # not be tested as plain arguments and then interpreted by the client.
      handlers = map (hook: hook // { command = lib.escapeShellArgs hook.argv; }) declared;
      manifest = pkgs.writeText "${name}-declarations.json" (builtins.toJSON handlers);
      claude = pkgs.writeText "${name}-claude.json" (
        builtins.toJSON {
          allowManagedHooksOnly = true;
          hooks = hooksFor "claude" handlers;
          inherit statusLine;
        }
      );
      codex = (pkgs.formats.toml { }).generate "${name}-codex.toml" {
        allow_managed_hooks_only = true;
        features.hooks = true;
        hooks = hooksFor "codex" handlers;
      };
    in
    pkgs.runCommand name { } ''
      ${lib.getExe pkgs.python3} ${./.}/contract.py \
        ${manifest} ${claude} ${codex} "$out" \
        ${lib.getExe' pkgs.coreutils "env"} ${lib.makeBinPath [ pkgs.coreutils ]}
    '';

  managed = contract "managed-agent-hooks" (map supervise declarations);
  badHook = pkgs.writeShellScript "bad-agent-hook" ''
    IFS= read -r input || true
    if [[ "$input" == '{' ]]; then
      echo 'missing hook dependency' >&2
      exit 2
    fi
  '';
  fixture = {
    name = "bad-hook";
    client = "claude";
    event = "SessionStart";
    matcher = "*";
    kind = "observe";
    timeout = 3;
    argv = [ (toString badHook) ];
  };
  supervisorFixture = pkgs.writeText "agent-hook-supervisor-fixtures.py" ''
    import json
    import sys
    import time

    mode = sys.argv[1]
    if mode == "exit":
        print('{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"}}')
        print("missing hook dependency\n" + "x" * 10000, file=sys.stderr)
        sys.exit(2)
    if mode == "sleep":
        time.sleep(60)
    if mode == "observe":
        print('{"decision":"block"}')
    if mode == "deny":
        print('{"continue":false}')
  '';
  supervisorFixtures =
    map
      (
        mode:
        fixture
        // {
          name = "supervisor-${mode}";
          kind = if mode == "exit" || mode == "deny" then "deny" else "observe";
          event = if mode == "exit" || mode == "deny" then "PreToolUse" else "SessionStart";
          argv = [
            (lib.getExe pkgs.python3)
            (toString supervisorFixture)
            mode
          ];
        }
      )
      [
        "exit"
        "sleep"
        "observe"
        "deny"
      ];
in
{
  inherit managed;
  tests = {
    agent-hooks = managed;
    agent-hooks-supervisor = contract "agent-hooks-supervisor" (map supervise supervisorFixtures);
    agent-hooks-reject-exit = pkgs.testers.testBuildFailure' {
      drv = contract "agent-hooks-bad-exit" [ fixture ];
      expectedBuilderLogEntries = [ "agent-hooks: bad-hook: exit 2: missing hook dependency" ];
    };
    agent-hooks-reject-stop = pkgs.testers.testBuildFailure' {
      drv = contract "agent-hooks-bad-stop" [ (fixture // { event = "Stop"; }) ];
      expectedBuilderLogEntries = [ "agent-hooks: forbidden event Stop" ];
    };
  };
}
