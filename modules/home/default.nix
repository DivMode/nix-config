{
  config,
  lib,
  local,
  pkgs,
  ...
}:
{
  imports = [
    ./ai
    ./archives.nix
    ./caches.nix
    ./development.nix
    ./downloads.nix
    ./fluidvoice.nix
    ./herdr
    ./karabiner.nix
    ./launchers.nix
    ./media.nix
    ./menu-bar.nix
    ./mouse.nix
    ./network-shares.nix
    ./privacy.nix
    ./projects.nix
    ./screensaver.nix
    ./secrets.nix
    ./terminal.nix
  ];

  # The signers git checks signatures against. Generated from the SAME local.nix
  # values that configure signing, so the key that signs and the key trusted to
  # verify cannot drift apart — declaring them separately is how a history stops
  # verifying after a key rotation, silently and long after the change.
  #
  # The principal is the committer email: git matches it against the identity on
  # the commit, so a mismatch reads as an untrusted signature rather than an
  # error, which is worse than no configuration at all.
  #
  # Public key material only. A private key must never reach this file, and
  # would be copied into the world-readable store if it did.
  xdg.configFile."git/allowed_signers".text = "${local.git.email} ${local.git.signingKey}\n";

  programs.git = {
    enable = true;

    # Machine-local files that a tool writes into whatever repository is open,
    # so they belong to this machine rather than to any one project. Ignoring
    # them here means a repository does not have to know the tool exists.
    #
    # Claude Code appends to `.claude/settings.local.json` on its own every time
    # a permission is approved. Left visible to git it shows up as an untracked
    # change in every repository, and on 2026-08-13 that blocked a deploy whose
    # precondition requires a clean tree — while the file itself was carrying
    # the only thing keeping the sandbox off, so it could not simply be deleted.
    # `**/.claude/.cc-writes/` was already in the unmanaged file this replaces.
    # It is carried over deliberately rather than dropped: taking ownership of
    # a file must not silently discard what it already contained.
    ignores = [
      "**/.claude/.cc-writes/"
      ".claude/settings.local.json"
    ];

    settings = {
      user = {
        inherit (local.git) name email;
        signingKey = local.git.signingKey;
      };
      init.defaultBranch = "main";
      pull.rebase = true;
      gpg = {
        format = "ssh";
        ssh.program = "/Applications/1Password.app/Contents/MacOS/op-ssh-sign";

        # Without this, git SIGNS correctly and then cannot verify what it just
        # signed: `git log --show-signature` reports "No signature" and %G?
        # yields N, on commits whose objects carry a complete BEGIN/END SSH
        # SIGNATURE block. Signing and verification are separate mechanisms and
        # only one of them was configured.
        #
        # Measured on 2026-08-21, and the timing is the point: it surfaced while
        # proving a moved SSH key could still sign, and for a moment it read as
        # a second failure stacked on the one being diagnosed. This reports
        # itself broken at exactly the moment you are checking whether you broke
        # something.
        #
        # GitHub verifies independently of this file, so nothing was wrong
        # upstream. This is about trusting your own history locally.
        ssh.allowedSignersFile = "${config.xdg.configHome}/git/allowed_signers";
      };
      commit.gpgSign = true;
      tag.gpgSign = true;
    };
  };

  programs.zsh = {
    enable = true;
    package = pkgs.zsh;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    defaultKeymap = "emacs";
    setOptions = [
      "INTERACTIVE_COMMENTS"
      "NO_BEEP"
    ];
    # The whole update as one typed word: scripts/update.sh moves every pinned
    # input forward, checks, builds, and activates. Arguments forward through
    # the alias, so `nixup --dry-run` and `nixup <input>` work as documented in
    # that script. The path comes from local.nix's project list because the
    # checkout location is machine identity, not configuration; on a machine
    # whose local.nix does not declare this repository the alias is simply
    # absent.
    #
    # Named `nixup` rather than `nixconfig` deliberately: that project entry
    # already generates a launcher function (projects.nix), and zsh expands
    # aliases before it looks up functions, so an alias of the same name would
    # silently shadow it. projects.nix reserves `nixup` for the same reason in
    # the other direction.
    shellAliases = lib.optionalAttrs (local.projects or { } ? nixconfig) {
      nixup = "${local.projects.nixconfig}/scripts/update.sh";
    };
    history = {
      path = "${config.xdg.stateHome}/zsh/history";
      size = 50000;
      save = 10000;
      expireDuplicatesFirst = true;
      extended = true;
      findNoDups = true;
      ignoreDups = true;
      ignoreSpace = true;
      share = true;
    };
  };

  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
  };

  # Home Manager is integrated into the nix-darwin generation. Do not install
  # the separate `home-manager` CLI or create a second activation path.
  programs.home-manager.enable = false;
  # The shared AI renderers own the Claude Code and Codex instruction files,
  # agent definitions, and Claude Code's user settings — including the
  # PreToolUse guard that enforces Nix-only machine changes. They are enabled
  # so that directory is reproducible: an agent, or anything else, can delete
  # ~/.claude and `darwin-rebuild switch` restores it from this repository.
  #
  # API-secret runtime injection stays dormant. SSH authentication and Git
  # signing are a separate 1Password capability.
  nixConfig.ai.enable = true;
  nixConfig.secrets.onePassword.enable = false;
  nixConfig.secrets.onePassword.sshAgent.enable = lib.mkDefault true;

  # A cached service-account token, exported from .zshenv. This is what stops
  # the desktop application prompting: a service account authenticates with no
  # app, no biometrics, and no controlling terminal, so non-interactive
  # processes read secrets silently. Independent of the dormant `enable` above,
  # which is the `op run` launcher, and of the SSH agent, which is the
  # application's own capability and keeps working either way.
  nixConfig.secrets.onePassword.serviceAccount.enable = true;

  # Connect credentials for the deploy path only. Cached to a 0600 env file that
  # the work monorepo's sst-connect-env.sh sources at the sst invocation seam, so
  # deploys use Connect — which does not spend the service account's rolling 24h
  # request cap — while interactive `op` keeps working with `--fields`.
  nixConfig.secrets.onePassword.connect.enable = true;

  # AWS profiles for the SST state bucket, resolved from 1Password per call.
  # ~/.aws did not exist at all after this machine was rebuilt — auth is
  # application-owned and so nothing restored it — which failed every infra
  # deploy with "aws: failed to get shared config profile, <profile>".
  # The profile definitions are declared; only the keys stay in 1Password.
  nixConfig.secrets.onePassword.aws.enable = true;

  # Home Manager refuses to replace an unmanaged file and aborts the whole
  # activation, which is what happened on 2026-08-13: a pre-existing global git
  # ignore file blocked every later step. Clear it, but ONLY on evidence that
  # its content is the single legacy line now carried in `programs.git.ignores`
  # above. Anything else means someone added rules that are not declared here,
  # and those must not be discarded silently.
  #
  # Depends on `checkLinkTargets` BY NAME. Both are entryBefore
  # [ "writeBoundary" ], which puts them in one DAG tier with no ordering
  # between them, and the check would otherwise run first and abort on the very
  # file this exists to clear.
  home.activation.claimGlobalGitIgnore = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
    globalIgnore="${config.xdg.configHome}/git/ignore"
    legacyContent='**/.claude/.cc-writes/'

    if [[ -f "$globalIgnore" && ! -L "$globalIgnore" ]]; then
      if [[ "$(< "$globalIgnore")" == "$legacyContent" ]]; then
        run rm -f "$globalIgnore"
      else
        errorEcho "Refusing to replace unmanaged file with unknown content: $globalIgnore"
        errorEcho "Add its rules to programs.git.ignores in modules/home/default.nix, then remove it."
        exit 1
      fi
    fi
  '';

  # Validate collisions before Home Manager begins writing any managed state.
  home.activation.validateScreenshotsDirectory = lib.hm.dag.entryBefore [ "writeBoundary" ] ''
    screenshotsDirectory="${config.home.homeDirectory}/Documents/Screenshots"
    if [[ -L "$screenshotsDirectory" || ( -e "$screenshotsDirectory" && ! -d "$screenshotsDirectory" ) ]]; then
      echo "Cannot create $screenshotsDirectory because a symlink or non-directory already exists" >&2
      exit 1
    fi
  '';

  # Screenshot.app requires its destination to exist as a normal writable
  # directory. `run` preserves Home Manager's dry-run behavior.
  home.activation.ensureScreenshotsDirectory = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run mkdir -p "${config.home.homeDirectory}/Documents/Screenshots"
  '';

  # Home Manager's App Management preflight makes activation impossible from an
  # agent session, so it is off. `copyApps` itself stays on — apps are still
  # copied, and Spotlight still indexes them.
  #
  # The check (home-manager modules/targets/darwin/copyapps.nix) touches
  # `.DS_Store` inside every bundle in ~/Applications/Home Manager Apps to probe
  # for kTCCServiceSystemPolicyAppBundles, and on failure runs
  # `tccutil reset SystemPolicyAppBundles` before probing once more. Two
  # consequences, both measured on 2026-08-14:
  #
  #   1. It runs unconditionally, so it aborts activations that would have
  #      copied nothing. Both failures that day were of exactly this shape —
  #      Ghostty.app was unchanged and there was no work for `copyApps` to do.
  #   2. macOS resolves the permission against the tree's RESPONSIBLE process,
  #      which inside a Claude Code session is the agent's own wrapper binary,
  #      not Ghostty. `/usr/bin/touch` on the bundle returns "Operation not
  #      permitted" from this session while the same command from a Ghostty tab
  #      succeeds. The wrapper lives on a Nix store path that changes on every
  #      update, so granting it the permission would not survive one.
  #
  # And the reset in step 1 is destructive: it revoked the App Management grant
  # the user had just given Ghostty, which is what produced the denial
  # notification. Skipping the preflight also skips that reset.
  #
  # What is lost: a real permission failure now surfaces as an rsync EPERM from
  # `copyApps` rather than a friendly message. That only happens when a bundle
  # genuinely changes — a Ghostty version bump — and it fails loudly, which is
  # the correct behaviour for the case the check was written for.
  targets.darwin.copyApps.enableChecks = false;

  # Bump only after reviewing Home Manager release notes.
  home.stateVersion = "26.05";
}
