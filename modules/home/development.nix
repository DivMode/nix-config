{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) system;

  # Claude Code comes from the llm-agents flake rather than the Homebrew cask.
  # Both deliver the same signed vendor binary, but the cask lags the release
  # stream badly: on 2026-08-13 the newest homebrew-cask commit still described
  # 2.1.223 while upstream was on 2.1.231. Since the tap is a pinned flake
  # input, no lock update could close that gap. See ../../docs/operations/rebuild.md.
  claudeCode = inputs.llm-agents.packages.${system}.claude-code;

  # Grafana's kubectl-style CLI for dashboards, alerts, metrics, logs and
  # traces, agent-optimized. Rebuilt from the flake-pinned release tag rather
  # than taken from nixpkgs as-is: nixpkgs trails upstream (1.0.0 against a
  # v1.1.0 released 2026-08-14), and ../ai loads the SAME source's
  # claude-plugin/ directory into Claude Code, so the binary and the skills
  # that describe it must move together. The derivation is finalAttrs-style,
  # so overriding version and src recomputes the tag-dependent ldflags;
  # vendorHash carries over until a Go dependency changes, at which point the
  # build fails with the new hash to declare here.
  #
  # Why it is declared at all: the work monorepo's health and alert-liveness
  # scripts spawn `gcx` from PATH and hard-exit without it. On 2026-08-16 its
  # absence on this machine read as a dead observability stack during a real
  # incident — a missing tool reading as a broken system, the expensive kind
  # of wrong.
  gcx = pkgs.gcx.overrideAttrs (old: {
    version = "1.1.0";
    src = inputs.gcx-src;
    vendorHash = "sha256-OvIK8sgWUo3t0+oure7+PpU7SFzbLyppyeaWQtKyZXg=";
    meta = old.meta // {
      changelog = "https://github.com/grafana/gcx/releases/tag/v1.1.0";
    };
  });

in
{
  options.nixConfig.claudeCode.package = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    default = claudeCode;
    description = ''
      The Claude Code package this configuration uses. Declared here because
      this module owns portable developer tooling, but INSTALLED by
      `programs.claude-code` in ../ai, which wraps it with `--plugin-dir` to
      load plugins. Only one of them may install it, or they collide on
      bin/claude.
    '';
  };

  config = {
    # Portable workstation tools come from the flake-declared nixpkgs input. Git and Zsh
    # are installed by their Home Manager program modules in default.nix.
    home.packages =
      (with pkgs; [
        gh
        fd
        jq
        just
        ripgrep
        mise
        uv
        rustup
        # Rust crates that vendor C/C++ (BoringSSL and friends, via *-sys build
        # scripts) shell out to cmake to compile it. Without it a from-scratch
        # cargo build of such a crate dies mid-gate with "is `cmake` not
        # installed?" — which surfaces only when a fresh worktree misses the
        # shared build cache, so it looks like a broken branch rather than a
        # missing tool. Declared here so it comes back with the machine.
        cmake
        # Package manager and runtime for repositories that declare it in
        # `packageManager`. It was previously a global install, so nothing
        # restored it when this machine was rebuilt and every task that shells
        # out to `bun` failed with "command not found". Declared here for the
        # same reason as everything else: it comes back with the machine.
        #
        # nixpkgs rather than Homebrew. This is a portable CLI, and Homebrew in
        # this configuration owns only native and vendor casks — a formula needs
        # a documented nixpkgs incompatibility, which trailing the latest
        # release by a single patch version is not.
        bun
        # Fetches subtitle and caption tracks, which is the only reliable way
        # to read a video's transcript from a shell: the pages are client-side
        # applications that serve a navigation shell to a plain fetch, the
        # unauthenticated caption endpoint returns nothing, and the third-party
        # transcript mirrors answer 403.
        yt-dlp
        # macOS ships no `flock`; it is a util-linux tool. Deploy scripts that
        # serialise themselves with a lock file need it, and without it they do
        # not fail cleanly — the one here reported a two-hour lock timeout,
        # while the actual error was `flock: command not found` on the line
        # below it. This is the standalone BSD-compatible implementation rather
        # than util-linux, which exists mainly for Linux.
        flock
        kubectl
        # Bare `pulumi` is only the CLI engine: its store path contains exactly
        # one executable, `bin/pulumi`. Every Pulumi program actually runs
        # inside a language host, a separate `pulumi-language-<runtime>`
        # process the engine looks for on PATH. Pulumi's own installer ships
        # the hosts with the engine; under Nix each is its own derivation, so
        # nothing here provided one and every TypeScript program — the
        # property-data repository's plain Pulumi stack — died before the first
        # resource with a missing language-host error (2026-08-15).
        #
        # `withPackages` is nixpkgs' sanctioned way to combine them, rather
        # than listing `pulumiPackages.pulumi-nodejs` beside the engine. It
        # builds a wrapper whose only executable is still `bin/pulumi`, with
        # the host's bin suffixed onto PATH for that process alone
        # (`makeCWrapper ... --suffix PATH`, readable in the wrapper binary).
        # So the host stays scoped to the engine instead of entering the
        # interactive PATH, and the two versions cannot drift apart across a
        # lock update.
        #
        # Every run still prints "using pulumi-language-nodejs from $PATH".
        # That is expected on this pin and not a misconfiguration: because the
        # wrapper hands the host over on PATH rather than installing it beside
        # the engine, Pulumi notes where it found it. A verified preview on
        # 2026-08-15 emitted the warning and then ran the program to
        # completion.
        (pulumi.withPackages (ps: [ ps.pulumi-nodejs ]))
        crane
        # The work monorepo's SST deploys drive the Pulumi gcp provider through
        # Application Default Credentials (`gcloud auth application-default
        # login` — one-time browser consent; JSON keys are blocked by org
        # policy, see that repository's ADR-0016). gcloud was a global install before
        # this machine was rebuilt, so nothing restored it and every infra
        # deploy failed with "could not find default credentials". The ADC
        # file itself is auth — application-owned, deliberately not declared.
        google-cloud-sdk
        # The remaining deploy-path CLIs the 2026-08 machine rebuild lost, all
        # found the same way — an sst deploy failing one tool at a time
        # (2026-08-14, during the work monorepo's #4116 deploy):
        #   oci         — the OKE kubeconfig authenticates through an exec
        #                 plugin that spawns `oci`; without it every OKE
        #                 resource reads as "unreachable cluster".
        #   cloudflared — `cloudflared access tcp` carries the pg-oke tunnel
        #                 the Atlas migration step connects through.
        #   atlas       — applies the SQL migrations over that tunnel.
        #   talosctl    — Talos cluster administration/debugging.
        oci-cli
        cloudflared
        atlas
        talosctl
        # Same rebuild loss, found the same way but by a GATE rather than a
        # deploy (2026-08-14): the work monorepo's pre-push helm-template-check
        # renders every Helm release with `helm template` before a push. Without
        # the binary it reported four charts as FAIL with "(no helm output)" —
        # a missing tool reading as four broken charts, which is the expensive
        # kind of wrong. The gate only fires on changes under
        # `infra/kubernetes-*.ts`, so it stayed invisible until one landed.
        kubernetes-helm
        # The //#lint:actions gate (the work monorepo's lint-actions.sh) shells
        # out to actionlint; a global install the 2026-08 rebuild lost. Found
        # when the turbo-inputs fix invalidated the long-cached gate and it
        # actually ran (2026-08-14).
        actionlint
        # Same gate family as helm and actionlint, but this one was never
        # declared anywhere at all — not nixpkgs, not Homebrew, not npm — and
        # it fails OPEN, which is why it went unnoticed. Lefthook runs the
        # commit-msg and pre-push guards in the property-data repository, and
        # the shims it writes into `.git/hooks/` walk a list of fallbacks
        # (`lefthook -h`, an npx cache path, node_modules, mise, uv, devbox)
        # and, when every one misses, print "Can't find lefthook in PATH" and
        # exit 0. Measured 2026-08-15: that clone's commit-msg hook returned 0
        # on a message that violates the conventional-commit rule it enforces,
        # so the guards had been passing by never running. A missing tool
        # reading as a green gate is worse than one reading as a red gate.
        lefthook
        # The minimal build retains the GDAL/OGR command suite plus VRT, WebP,
        # SQLite/MBTiles, and projection support without unrelated cloud drivers.
        gdalMinimal
        pmtiles
      ])
      ++ [
        inputs.herdr.packages.${system}.default
        # Outside the `with pkgs;` list so the name unambiguously means the
        # let-bound override above, not pkgs.gcx.
        gcx
      ];

    programs.zsh.initContent = lib.mkAfter ''
      eval "$(${lib.getExe pkgs.mise} activate zsh)"
    '';

    # This is a public fallback policy, not a project lock. Exact project runtime
    # versions belong in each project's repository.
    xdg.configFile."mise/config.toml".text = ''
      [tools]
      node = "24"
    '';
  };
}
