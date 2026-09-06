{
  config,
  lib,
  local,
  pkgs,
  ...
}:
let
  inherit (lib)
    attrNames
    filterAttrs
    hasSuffix
    listToAttrs
    nameValuePair
    ;

  # The Command Governor checkout on this machine. It is machine identity, not
  # configuration, so it is read from the ignored local.nix exactly like every
  # other project path — and from the SAME attribute the `p` jump function and
  # the project shell function already use, because a second copy of a path is
  # two things that will disagree later.
  #
  # A machine without that checkout declared gets nothing from this module: no
  # command, no global Prime configuration, no activation entry.
  checkout = local.projects.commandgovernor or null;

  harness = "${checkout}/harness";

  # Evaluation must not hard-fail on a machine where the repository has not been
  # cloned yet — scripts/setup-mac.sh restores local.nix, which declares this
  # project, before any checkout exists, and a wiped Mac has to be able to
  # rebuild. But it must not be silent either, because the alternative is a `pi`
  # that vanished with no explanation. Warn once, at the rebuild that would have
  # installed it. A checkout that disappears BETWEEN this check and activation
  # is a different case and fails loudly; see command-governor-settings.sh.
  present = checkout != null && builtins.pathExists "${harness}/settings.project.json";
  enable = lib.warnIf (checkout != null && !present) ''
    local.nix declares a Command Governor checkout at the projects.commandgovernor
    path, but ${harness}/settings.project.json is not there. The `pi` command and
    the global Prime Agent configuration are NOT installed by this activation.
    Clone the repository to that path and rebuild.
  '' present;

  # Prime Agent's CONFIG_DIR_NAME (dist/config.js): the per-user agent directory
  # is $HOME/.prime/agent, and the project one is <project>/.prime/agent. Prime
  # reads settings.json from both and merges them, project winning; skills,
  # prompts, extensions and themes are auto-discovered from the same two roots
  # (dist/core/package-manager.js, addAutoDiscoveredResources).
  agentDir = ".prime/agent";

  # The activation writer, shared with the flake check that tests it.
  settings = import ./command-governor-settings.nix { inherit pkgs; };

  # One symlink per harness file rather than one for the whole directory, so the
  # parent directories stay real and writable. Prime does not write into them
  # today — its npm packages go to `npm root -g`, not here — but a directory
  # symlink would send any future write straight into the Command Governor
  # checkout, silently editing another repository's tracked files.
  outOfStore = config.lib.file.mkOutOfStoreSymlink;

  markdownIn =
    directory:
    attrNames (
      filterAttrs (name: type: type == "regular" && hasSuffix ".md" name) (builtins.readDir directory)
    );

  directoriesIn =
    directory: attrNames (filterAttrs (_name: type: type == "directory") (builtins.readDir directory));

  linkFiles =
    target: directory: names:
    listToAttrs (
      map (
        name:
        nameValuePair "${agentDir}/${target}/${name}" {
          source = outOfStore "${directory}/${name}";
        }
      ) names
    );

  # The harness's role files, skills and prompts in Prime's global locations,
  # linked rather than copied: the checkout stays the source of truth for its own
  # harness content, and editing a role file there takes effect immediately.
  # Only the file NAMES are read at evaluation time, so nothing about the harness
  # is duplicated into this repository — but adding a role file to the checkout
  # does need a rebuild here for the link to appear.
  #
  # `agents` is not one of Prime's own resource types. @gotgenes/pi-subagents
  # reads role files from `join(getAgentDir(), "agents")` for global scope and
  # `<cwd>/.pi/agents` for project scope (src/config/custom-agents.ts), and
  # getAgentDir() is Prime's — so the global location is ~/.prime/agent/agents.
  # That is the whole reason a project no longer has to copy harness/agents/
  # into its own .pi/agents/.
  harnessLinks =
    linkFiles "agents" "${harness}/agents" (markdownIn "${harness}/agents")
    // linkFiles "prompts" "${harness}/prompts" (markdownIn "${harness}/prompts")
    // listToAttrs (
      map (
        name:
        nameValuePair "${agentDir}/skills/${name}" {
          source = outOfStore "${harness}/skills/${name}";
        }
      ) (directoriesIn "${harness}/skills")
    );

  # The command itself.
  #
  # A wrapper that execs the checkout's pinned tree, deliberately, rather than a
  # Nix package built from the Prime Agent release. pins/ is Command Governor's
  # source of truth and scripts/bootstrap.sh is what verifies the release assets
  # against two checksum authorities AND applies the committed patches — the
  # patched pi-claude-agent-sdk bridge is the only reason Claude models run on
  # the Max-plan login instead of an API key. A fresh npm install of the
  # upstream packages would be a different, unpatched, unverified tree wearing
  # the same version number. So this repository declares the command; the
  # checkout keeps owning what the command runs.
  #
  # The binary is reached through pins/current, the version-stable symlink that
  # repository's bootstrap maintains, and it is resolved at RUN time rather than
  # evaluation time — so moving the pin forward there needs no rebuild here and
  # puts no version number in this repository to go stale.
  #
  # `pi` is Command Governor's pinned Prime Agent (a Pi fork), not upstream
  # pi.dev's `pi`; Prime's own package installs only `prime-agent`, and nothing
  # else on this machine provides bin/pi. Installing upstream pi later would
  # collide here, on purpose and visibly.
  primeAgentWrapper = pkgs.writeShellApplication {
    name = "prime-agent";
    runtimeInputs = [ pkgs.nodejs ];
    text = ''
      checkout=${lib.escapeShellArg (toString checkout)}

      # pins/current is Command Governor's version-stable entry point: a symlink
      # its scripts/bootstrap.sh maintains, pointing at whichever install root
      # pins.json currently names. Going through it means re-pinning Prime is
      # entirely that repository's business — no rebuild here, and no version
      # number written down in nix-config to go stale. The previous install root
      # is left in place by that bootstrap, so a daemon already running on the
      # old tree keeps working across a re-pin.
      binary="$checkout/pins/current/node_modules/.bin/prime-agent"

      if [ ! -d "$checkout" ]; then
        printf 'prime-agent: no Command Governor checkout at %s\n' "$checkout" >&2
        printf '  local.nix declares it as projects.commandgovernor. Clone the\n' >&2
        printf '  repository to that path, then run its scripts/bootstrap.sh.\n' >&2
        exit 1
      fi

      # One test covers both a missing pins/current and an install root that has
      # no binary in it, because the answer is the same either way: bootstrap.sh
      # is what creates the symlink AND what fills the tree it points at.
      if [ ! -x "$binary" ]; then
        printf 'prime-agent: the pinned Prime Agent is not installed.\n' >&2
        printf '  Expected an executable at %s\n' "$binary" >&2
        printf '  Run %s/scripts/bootstrap.sh to verify and install it.\n' "$checkout" >&2
        exit 1
      fi

      # node comes from runtimeInputs above, so `pi` works in any environment
      # rather than only in a shell where the version manager that ran
      # bootstrap.sh happens to be initialised.
      #
      # That deterministic node has a read-only global npm prefix inside the
      # Nix store, and Prime installs its user-scope packages with
      # `npm install -g` (dist/core/package-manager.js, installNpm). Point npm
      # at a writable prefix inside Prime's own state directory, and put its
      # bin on PATH so anything installed there is reachable. Without this the
      # first start fails trying to write into /nix/store.
      export NPM_CONFIG_PREFIX="''${NPM_CONFIG_PREFIX:-$HOME/${agentDir}/npm-global}"
      mkdir -p "$NPM_CONFIG_PREFIX/bin"
      export PATH="$NPM_CONFIG_PREFIX/bin:$PATH"

      exec "$binary" "$@"
    '';
  };

  # `pi` is the name typed; `prime-agent` is the name the substrate is published
  # under and what every Command Governor document and error message says. Both
  # are the same wrapper, so they can never drift into two behaviours.
  commandGovernor = pkgs.runCommand "command-governor-prime-agent" { } ''
    mkdir -p "$out/bin"
    ln -s ${primeAgentWrapper}/bin/prime-agent "$out/bin/prime-agent"
    ln -s ${primeAgentWrapper}/bin/prime-agent "$out/bin/pi"
  '';
in
{
  config = lib.mkIf enable {
    home.packages = [ commandGovernor ];

    home.file = harnessLinks;

    # ~/.prime/agent/settings.json cannot be a store symlink: Prime writes to it
    # (telemetry acknowledgement, recent models, auth migration, package
    # installs), and it already exists as a real file on this machine. So the
    # declared keys are MERGED into the live file on every activation, exactly
    # as modules/home/ai/default.nix does for Claude Code's settings.json.
    #
    # What is declared is read from the checkout's harness/settings.project.json
    # at activation time — not from a copy in this repository, and not baked in
    # at evaluation time. Command Governor owns that list, its conformance suite
    # checks it against pins/pins.json, and moving the pin forward there needs no
    # rebuild here. The script does the ../../ → absolute rewrite the global
    # location requires, and fails the activation if the file is gone or holds a
    # package spelling it cannot resolve.
    home.activation.installPrimeAgentSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${pkgs.runtimeShell} ${settings.writer} \
        ${lib.getExe pkgs.jq} ${lib.escapeShellArg (toString checkout)} "$HOME/${agentDir}"
    '';
  };
}
