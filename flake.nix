{
  description = "Public multi-host Nix configuration for macOS and future NixOS servers";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Packages for AI coding agents, updated daily by upstream automation:
    # Herdr and ccstatusline come from here. Claude Code no longer does — it
    # updates itself; see modules/home/development.nix.
    #
    # Its nixpkgs is deliberately NOT followed to ours. This input pins
    # nixpkgs-unstable, and overriding that would rebuild every derivation away
    # from what upstream tests and publishes to its own binary cache, for no
    # benefit — the package is a signed vendor binary plus a wrapper.
    llm-agents.url = "github:numtide/llm-agents.nix";

    # Matt Pocock's engineering skills. Consumed as a pinned source tree rather
    # than installed with `claude plugins install`, which writes mutable state
    # this repository could not restore. MIT licensed, so nothing is vendored:
    # only referenced, and updated with `./scripts/update.sh mattpocock-skills`.
    mattpocock-skills = {
      url = "github:mattpocock/skills";
      flake = false;
    };

    # Anthropic's own example skills. Upstream ships a marketplace but no
    # plugin manifest at the root, so it cannot be loaded as one plugin the way
    # mattpocock-skills is; modules/home/ai selects individual skill
    # directories from it for Claude Code instead — what `npx skills add`
    # does, minus the mutable copy under ~/.claude. Apache-2.0, referenced not
    # vendored, and updated with `./scripts/update.sh anthropic-skills`.
    anthropic-skills = {
      url = "github:anthropics/skills";
      flake = false;
    };

    # Paul Bakaus's Impeccable design skill, which grew out of Anthropic's
    # frontend-design. Upstream installs it with `npx skills add` or its
    # plugin marketplace, both of which write a mutable copy under ~/.claude;
    # modules/home/ai builds the skill directory from this pinned tree
    # instead. Apache-2.0, referenced not vendored, and updated with
    # `./scripts/update.sh impeccable`.
    impeccable = {
      url = "github:pbakaus/impeccable";
      flake = false;
    };

    # Alchemy, pinned to the release tag of the @alchemy.run/domain version the
    # projects install, for the alchemy-domain skill that package ships
    # (packages/domain/skills/alchemy-domain). The tag, not main: upstream main
    # already changes the Domain API the skill teaches (Api.testClient became
    # clientInProcess, Story stubs changed), so a main-tracking skill would
    # teach calls the installed package does not have. `./scripts/update.sh`
    # excludes this input from its release-tag moves, because upstream's
    # latest release is not necessarily the one the projects install: move
    # this tag by hand when the projects move to a new Alchemy release.
    # Apache-2.0, referenced not vendored.
    alchemy-src = {
      url = "github:alchemy-run/alchemy/v2.0.0-beta.84";
      flake = false;
    };

    # iOS and App Store skills, for every native Apple project on this Mac
    # (modules/home/ai selects the directories). All MIT, referenced not
    # vendored, and moved by `nix flake update`.
    #
    # asc-skills teaches the `asc` App Store Connect CLI that homebrew.nix
    # installs. Its commits follow asc releases ("sync skills with asc X"), so
    # when Homebrew moves asc, update this input in the same change; a skill
    # written for a newer or older asc teaches commands the binary lacks.
    asc-skills = {
      url = "github:rorkai/app-store-connect-cli-skills";
      flake = false;
    };
    # Rejection-pattern preflight against the App Review Guidelines; its
    # SKILL.md records which guideline revision it is synced to.
    app-store-preflight-skills = {
      url = "github:truongduy2611/app-store-preflight-skills";
      flake = false;
    };
    # Paul Hudson's Swift skills, one repository each.
    swiftui-skill = {
      url = "github:twostraws/SwiftUI-Agent-Skill";
      flake = false;
    };
    swift-concurrency-skill = {
      url = "github:twostraws/Swift-Concurrency-Agent-Skill";
      flake = false;
    };
    swift-testing-skill = {
      url = "github:twostraws/Swift-Testing-Agent-Skill";
      flake = false;
    };

    # Grafana's gcx CLI, pinned to a release tag. One input feeds two
    # consumers: modules/home/development.nix builds the CLI binary from it
    # (nixpkgs packages gcx, but its pinned release trails upstream), and
    # modules/home/ai loads the repository's claude-plugin/ directory as a
    # Claude Code plugin. Building both from the same pin keeps the binary and
    # the skills that describe it at one version by construction.
    #
    # A tag pin does not advance with `nix flake update`, so
    # `./scripts/update.sh` moves it: on a full run, or `update.sh gcx`, it
    # rewrites this tag to the latest GitHub release, re-locks, and refreshes
    # the Go vendor hash in modules/home/gcx-pin.json when it changed. The tag
    # is a tag rather than the default branch because gcx's version string and
    # release notes are derived from it.
    gcx-src = {
      url = "github:grafana/gcx/v1.7.1";
      flake = false;
    };

    # Claude Code plugin that dispatches scoped work to the Codex CLI and keeps
    # each execution's prompt, raw events, and handoff. Pinned to the v0.5.1
    # tag (a pre-release on upstream's release/0.5.1 branch, never merged to
    # main): it adds the background runner the skills launch Codex through,
    # which v0.5.0 lacks. modules/home/ai loads it as a plugin and layers the
    # local delegation policy onto it. MIT; referenced, not vendored. A tag
    # pin does not move with `nix flake update`; edit the tag to upgrade.
    codex-orchestrator = {
      url = "github:alexzh3/codex-orchestrator/v0.6.0";
      flake = false;
    };

    nix-homebrew.url = "github:zhaofengli/nix-homebrew";

    homebrew-core = {
      url = "github:homebrew/homebrew-core";
      flake = false;
    };

    homebrew-cask = {
      url = "github:homebrew/homebrew-cask";
      flake = false;
    };

    # The memory brake (modules/darwin/membrake.nix): our own public
    # repository, moved by `nix flake update`. It builds with this flake's
    # nixpkgs so there is one nixpkgs in the closure.
    membrake = {
      url = "github:DivMode/membrake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      nixpkgs,
      nix-darwin,
      ...
    }:
    let
      localPath = builtins.getEnv "NIX_CONFIG_LOCAL";
      rawLocal =
        if localPath == "" then
          import ./local.example.nix
        else if builtins.substring 0 1 localPath != "/" then
          throw "NIX_CONFIG_LOCAL must be an absolute path"
        else
          import (builtins.toPath localPath);
      requiredLocalFields = [
        "user"
        "system"
        "homeDirectory"
        "git"
        "onePassword"
        "downloadsDirectory"
      ];
      missingLocalFields = builtins.filter (name: !(builtins.hasAttr name rawLocal)) requiredLocalFields;
      gitFieldsPresent =
        rawLocal ? git
        && builtins.isAttrs rawLocal.git
        && builtins.all (name: builtins.hasAttr name rawLocal.git) [
          "name"
          "email"
          "signingKey"
          "signingKeyReference"
        ];
      local =
        if missingLocalFields != [ ] then
          throw "local.nix is missing one or more required top-level fields; compare it with local.example.nix"
        else if !gitFieldsPresent then
          throw "local.nix git must define name, email, signingKey, and signingKeyReference; preserve existing fields and add the signing key reference from local.example.nix"
        else if
          !(builtins.all (value: builtins.isString value && value != "") [
            rawLocal.user
            rawLocal.system
            rawLocal.homeDirectory
            rawLocal.git.name
            rawLocal.git.email
            rawLocal.git.signingKey
            rawLocal.git.signingKeyReference
          ])
        then
          throw "local.nix identity values must be non-empty strings"
        else if builtins.match "^/Users/[^/]+$" rawLocal.homeDirectory == null then
          throw "local.nix homeDirectory must be an absolute /Users/<name> path"
        else if
          !(builtins.isString rawLocal.downloadsDirectory)
          || builtins.match "^/.+[^/]$" rawLocal.downloadsDirectory == null
        then
          throw "local.nix downloadsDirectory must be an absolute path with no trailing slash; Chrome's DownloadDirectory policy has no fallback, so it must also name a location that is always present"
        else if
          !(builtins.elem rawLocal.system [
            "aarch64-darwin"
            "x86_64-darwin"
          ])
        then
          throw "local.nix system must be a supported Darwin architecture"
        else if builtins.match "^[^[:space:]@]+@[^[:space:]@]+$" rawLocal.git.email == null then
          throw "local.nix git.email must be a valid non-empty commit email"
        else if builtins.match "^ssh-ed25519 [A-Za-z0-9+/=]+( .*)?$" rawLocal.git.signingKey == null then
          throw "local.nix git.signingKey must be an Ed25519 SSH public key, never private-key material"
        else
          rawLocal;
      localConfigured = localPath != "";
      ai = import ./ai;
      agentHooks =
        system:
        import ai.hooks {
          pkgs = nixpkgs.legacyPackages.${system};
          statusLine =
            (import ./modules/home/ai/ccstatusline.nix {
              inherit inputs;
              inherit (nixpkgs) lib;
              pkgs = nixpkgs.legacyPackages.${system};
            }).statusLine;
        };
    in
    {
      darwinConfigurations.example-mac = nix-darwin.lib.darwinSystem {
        inherit (local) system;
        specialArgs = {
          inherit
            inputs
            local
            localConfigured
            ai
            ;
        };
        modules = [ ./hosts/example-mac ];
      };

      checks =
        nixpkgs.lib.genAttrs
          [
            "aarch64-darwin"
            "x86_64-darwin"
            "aarch64-linux"
            "x86_64-linux"
          ]
          (system: {
            inherit ((agentHooks system).tests)
              agent-hooks
              agent-hooks-reject-exit
              agent-hooks-reject-stop
              agent-hooks-supervisor
              ;
            shell-bootstrap-hashes =
              let
                pkgs = nixpkgs.legacyPackages.${system};
              in
              pkgs.runCommand "shell-bootstrap-hash-tests" { } ''
                ${pkgs.python3}/bin/python3 \
                  ${./scripts/check-shell-bootstrap.py} \
                  ${./modules/darwin/default.nix}
                touch "$out"
              '';
            agent-instructions = (import ./ai/instructions { pkgs = nixpkgs.legacyPackages.${system}; }).tests;
            codex-journal =
              let
                pkgs = nixpkgs.legacyPackages.${system};
                journal = import ./ai/codex-orchestrator/codex-journal.nix { inherit pkgs; };
              in
              pkgs.runCommand "codex-journal-tests"
                {
                  nativeBuildInputs = [
                    pkgs.bash
                    pkgs.git
                    pkgs.jq
                    pkgs.python3
                  ];
                }
                ''
                  repo="$TMPDIR/example-repo"
                  git init --initial-branch=example-branch "$repo"
                  git -C "$repo" -c user.name=Example -c user.email=example@example.invalid \
                    commit --allow-empty -m 'Example baseline'
                  if ! bash ${ai.codexOrchestrator.journalTest} \
                    ${pkgs.lib.getExe journal} ${inputs.codex-orchestrator} \
                    "$repo" "$TMPDIR/evidence"; then
                    find "$TMPDIR/evidence" -type f ! -path '*/plugin/*' -print -exec cat {} \;
                    exit 1
                  fi
                  echo 'codex-journal tests passed' > "$out"
                '';
            orchestration-docs = (import ./docs/links.nix { pkgs = nixpkgs.legacyPackages.${system}; }).tests;
            codex-config-merge = (import ./ai/codex { pkgs = nixpkgs.legacyPackages.${system}; }).tests;
            command-governor-settings =
              (import ./modules/home/command-governor-settings.nix {
                pkgs = nixpkgs.legacyPackages.${system};
              }).tests;
            cli-proxy-state =
              let
                pkgs = nixpkgs.legacyPackages.${system};
                python = pkgs.python3.withPackages (p: [
                  p.pyyaml
                ]);
              in
              pkgs.runCommand "cli-proxy-state-tests" { } ''
                cp ${./modules/home/cli-proxy-state.py} cli-proxy-state.py
                cp ${./modules/home/cli-proxy-state-test.py} cli-proxy-state-test.py
                ${python}/bin/python3 cli-proxy-state-test.py
                touch "$out"
              '';
            # The signal guard agent shells load (ai/shell-guard), run in every
            # shell it must work in: Nix's bash and zsh, and the system's own
            # (scripts with a /bin/bash shebang get bash 3.2; both clients run
            # commands in /bin/zsh). macOS only (a null attribute name is
            # omitted): the test starts its processes with the system's
            # /usr/bin/perl and /bin/sleep. The build cannot execute /bin/ps,
            # so the guard's fallback finds this ps on PATH. The test signals
            # only processes it started itself.
            ${if nixpkgs.lib.hasSuffix "-darwin" system then "agent-kill-guard" else null} =
              let
                pkgs = nixpkgs.legacyPackages.${system};
              in
              pkgs.runCommand "agent-kill-guard-tests" { nativeBuildInputs = [ pkgs.ps ]; } ''
                names="$(${pkgs.python3}/bin/python3 -c '
                import importlib.util, sys
                spec = importlib.util.spec_from_file_location("nix_only_guard", sys.argv[1])
                guard = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(guard)
                print(" ".join(sorted(guard.SELF_RESTARTING_UI_AGENTS)))
                ' ${./ai/hooks/nix-only-guard.py})"
                # nix-darwin's /etc/zshenv replaces PATH unless this is set,
                # and the zsh runs would then find /bin/ps again.
                export __NIX_DARWIN_SET_ENVIRONMENT_DONE=1
                for shell in ${pkgs.bash}/bin/bash ${pkgs.zsh}/bin/zsh /bin/bash /bin/zsh; do
                  echo "kill-guard tests in $shell"
                  "$shell" ${ai.shellGuard.killGuardTest} ${ai.shellGuard.killGuard} "$names"
                done
                touch "$out"
              '';
          });

      # `nixfmt-tree`, not bare `nixfmt`. `nix fmt` invokes the formatter with
      # the paths to format, and passing none makes bare `nixfmt` read stdin —
      # so the documented `nix fmt` workflow silently formatted nothing and
      # exited non-zero with "unexpected end of input". The treefmt wrapper
      # formats the whole tree when invoked with no arguments, which is what
      # AGENTS.md, README.md, and docs/operations/rebuild.md all tell you to do.
      formatter.aarch64-darwin = nixpkgs.legacyPackages.aarch64-darwin.nixfmt-tree;
      formatter.x86_64-darwin = nixpkgs.legacyPackages.x86_64-darwin.nixfmt-tree;
      formatter.aarch64-linux = nixpkgs.legacyPackages.aarch64-linux.nixfmt-tree;
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt-tree;
    };
}
