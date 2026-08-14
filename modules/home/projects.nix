{
  lib,
  local,
  ...
}:
let
  inherit (lib)
    attrNames
    concatMapStringsSep
    concatStringsSep
    escapeShellArg
    mapAttrsToList
    ;

  # Project directories are machine identity, not configuration. They live in
  # the git-ignored local.nix so this public repository never carries the names
  # of private work, exactly as the Git identity and 1Password item IDs do.
  # scripts/rebuild.sh syncs local.nix to 1Password after every successful
  # activation, so the list survives a wiped machine.
  #
  # These are paths, not secrets. They are still written into the world-readable
  # Nix store as part of .zshrc, which is the same exposure as the home
  # directory path already declared here. Never put a token or a private URL in
  # this attribute set — that is the boundary AGENTS.md draws.
  projects = local.projects or { };

  names = attrNames projects;

  # A generated function shadows any command of the same name, so a project
  # called `cd`, `git`, or `test` would quietly break the shell. Fail at
  # evaluation rather than let the machine activate into that state.
  reserved = [
    "cd"
    "do"
    "done"
    "echo"
    "else"
    "esac"
    "fi"
    "for"
    "function"
    "git"
    "if"
    "in"
    "just"
    "kill"
    "nix"
    "p"
    "set"
    "test"
    "then"
    "time"
    "while"
  ];

  collisions = builtins.filter (n: builtins.elem n reserved) names;

  # zsh function names may not contain characters the parser treats specially.
  # A repository directory can legally be named `data-table-filters`, which is
  # fine, or `my project`, which is not.
  malformed = builtins.filter (n: builtins.match "[a-zA-Z_][a-zA-Z0-9_-]*" n == null) names;

  # One function per project: change directory, then start Claude Code there.
  #
  # `claude` is called by NAME, deliberately, not by store path. The Home
  # Manager claude-code module wraps the package with `--plugin-dir` to install
  # plugins, and secrets.nix may replace bin/claude with a 1Password launcher.
  # A hard-coded store path would silently bypass whichever of those is active.
  #
  # `"$@"` forwards arguments, so `<name> -c` continues that project's last
  # conversation and `<name> -p "..."` runs one non-interactively.
  #
  # The `cd` is not undone on exit. That is the point: leaving the shell in the
  # project directory makes the bare name double as a jump when Claude Code is
  # closed immediately.
  projectFunction = name: path: ''
    ${name}() {
      cd ${escapeShellArg path} || return 1
      command claude --dangerously-skip-permissions "$@"
    }
  '';

  # Jump without starting an agent. The bare project name always launches
  # Claude Code, so this is the way to simply be in the directory.
  jumpFunction = ''
    p() {
      case "$1" in
        ${concatMapStringsSep "\n        " (n: "${n}) cd ${escapeShellArg projects.${n}} ;;") names}
        *)
          print -u2 "p: unknown project: ''${1:-<none>}"
          print -u2 "known: ${concatStringsSep " " names}"
          return 1
          ;;
      esac
    }

    _nix_config_projects() { compadd ${concatStringsSep " " names} }
    compdef _nix_config_projects p
  '';
in
{
  assertions = [
    {
      assertion = collisions == [ ];
      message = ''
        local.nix declares project names that would shadow a shell builtin or a
        command this configuration relies on: ${concatStringsSep ", " collisions}.
        Rename the entry; the attribute name is the shell function name.
      '';
    }
    {
      assertion = malformed == [ ];
      message = ''
        local.nix declares project names that are not valid shell function
        names: ${concatStringsSep ", " malformed}.
        Use letters, digits, underscores, and hyphens, starting with a letter.
      '';
    }
  ];

  programs.zsh.initContent = lib.mkIf (projects != { }) (
    lib.mkAfter (concatStringsSep "\n" (mapAttrsToList projectFunction projects) + "\n" + jumpFunction)
  );
}
