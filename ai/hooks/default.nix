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

  declarations = [
    {
      name = "nix-only-guard";
      client = "claude";
      event = "PreToolUse";
      matcher = "Bash";
      kind = "deny";
      timeout = 10;
      argv = [
        (lib.getExe pkgs.python3)
        "${./nix-only-guard.py}"
      ];
      probes = [
        {
          command = "brew install example";
          deny = true;
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
