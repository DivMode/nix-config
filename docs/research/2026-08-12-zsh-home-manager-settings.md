# Zsh settings through Home Manager

> Update (2026-08-13): the native Zsh recommendation remains current. Starship
> was subsequently selected as the declarative prompt; Oh My Zsh remains
> intentionally absent. See `2026-08-13-jetbrains-mono-starship-zsh.md`.

Date: 2026-08-12

## Recommendation

Keep Zsh entirely under Nix and Home Manager. The current foundation is sound:
Home Manager already owns the pinned Zsh package, completion,
`zsh-autosuggestions`, `zsh-syntax-highlighting`, and the mise activation hook.
The useful next increment is deliberately small:

1. Make history policy explicit and keep the mutable history file in
   `${config.xdg.stateHome}/zsh/history`.
2. Add Home Manager's `fzf` module with Zsh integration for fuzzy `Ctrl-R`, file
   insertion, and directory navigation.
3. Select the Emacs keymap explicitly and enable interactive comments.
4. Keep the existing autosuggestion and syntax-highlighting modules.
5. Do not add Oh My Zsh, a plugin manager, a cloud history service, a large alias
   collection, or a custom prompt yet.

This is a restrained, portable baseline for macOS and future NixOS hosts. It
avoids a second package owner, network-fetched shell code, and shell behavior
that is difficult to explain or reproduce.

## What was configured before this change

Before this change, the repository declared the following in
`modules/home/default.nix`:

- `programs.zsh.enable = true`
- `programs.zsh.package = pkgs.zsh`
- completion enabled
- autosuggestions enabled
- syntax highlighting enabled

`modules/home/development.nix` appends an absolute, Nix-resolved mise activation:

```sh
eval "$(/nix/store/...-mise/bin/mise activate zsh)"
```

That placement is supported by mise: its official documentation says
`mise activate zsh` belongs in the shell rc file and recommends an absolute
executable path when mise is not already on `PATH` ([mise activation
documentation](https://mise.jdx.dev/cli/activate.html)). Home Manager 26.05's
`initContent` ordering puts `lib.mkAfter` content last, after Home Manager's
managed completion and plugin initialization ([Home Manager Zsh
source](https://github.com/nix-community/home-manager/blob/release-26.05/modules/programs/zsh/default.nix)).

Because no history sub-options are declared, Home Manager 26.05 supplies its
defaults:

| Setting | Effective default |
| --- | --- |
| In-memory history size | 10,000 |
| Saved history size | 10,000 |
| History path | `${programs.zsh.dotDir}/.zsh_history` |
| Ignore immediately repeated command | enabled |
| Ignore a command beginning with a space | enabled |
| Share history among local Zsh sessions | enabled |
| Extended timestamps/durations | disabled as an explicit option; `SHARE_HISTORY` writes timestamped records itself |
| Remove all duplicates | disabled |
| Preferentially expire duplicates | disabled |
| Hide duplicates during history search | disabled |

Home Manager also always enables `HIST_FCNTL_LOCK`. These values and the mapping
to Zsh options are defined in the official [Home Manager 26.05 history
module](https://github.com/nix-community/home-manager/blob/release-26.05/modules/programs/zsh/history.nix).

Before this change, no aliases, custom functions, keymap, prompt, `fzf`,
Starship, Oh My Zsh, or history-substring-search were declared.

The configuration has not been activated on this Mac. A narrow read-only check
found that the live login shell is still Apple's `/bin/zsh` 5.9, `ZDOTDIR` is
unset, no `~/.zshrc` is present, and the only user startup file found was
`~/.zshenv`, which sources Cargo's environment file. Therefore the declarative
completion, suggestions, highlighting, and mise hook are desired state, not the
current live shell behavior.

## Implemented history policy

The Home Manager configuration now declares:

```nix
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
```

Rationale:

- Shell history is mutable state, not declarative configuration. The XDG Base
  Directory specification specifically lists action history under
  `$XDG_STATE_HOME`, whose default is `~/.local/state` ([XDG Base Directory
  specification](https://specifications.freedesktop.org/basedir-spec/latest/)).
- A 50,000-entry in-memory list with a 10,000-entry saved file gives
  `HIST_EXPIRE_DUPS_FIRST` room to discard duplicate entries before unique ones.
  Zsh explicitly says `HISTSIZE` must be larger than `SAVEHIST` for that option
  to work as intended ([Zsh history options](https://zsh.sourceforge.io/Doc/Release/Options.html#History)).
- `HIST_FIND_NO_DUPS` avoids showing the same command repeatedly during search
  without destroying every older occurrence from the chronological history.
- `SHARE_HISTORY` imports commands from other local Zsh sessions and appends new
  commands incrementally. Zsh documents that it should not be combined with
  `INC_APPEND_HISTORY`; Home Manager's `share = true` and default
  `append = false` already honor that relationship ([Zsh history
  options](https://zsh.sourceforge.io/Doc/Release/Options.html#History)).
- Explicit `extended = true` records start time and duration consistently and
  documents the intent, although shared-history records are timestamped by Zsh
  even without it.

Do not put the history file in iCloud Drive, Git, this public repository, an
external shared volume, or any cross-machine synchronization system. History is
mutable and can contain repository names, hostnames, paths, arguments, and
accidentally pasted credentials. AWS's security guidance specifically warns
that shell history and other console utilities can expose command parameters
and recommends passing secret material through a file or another mechanism that
does not place the secret on the command line ([AWS Secrets Manager security
guidance](https://docs.aws.amazon.com/secretsmanager/latest/userguide/security_cli-exposure-risks.html)).

`ignoreSpace = true` is a useful last-resort escape hatch: Zsh removes a command
that begins with a space from persisted history after the next command is
entered. It is not a complete secret-handling system. Prefer 1Password runtime
injection such as `op run` or `op plugin run`, which supplies credentials at
runtime instead of embedding plaintext in scripts or aliases ([1Password CLI
secret-loading documentation](https://developer.1password.com/docs/cli/secrets-scripts)).

## Completion, suggestions, highlighting, and search

Keep all three existing features:

- Home Manager's completion support adds Nix completions and runs `compinit`.
- The Home Manager autosuggestion module sources its pinned Nixpkgs package and
  defaults to the upstream `history` strategy. The upstream project performs
  suggestions asynchronously on supported Zsh versions and documents history,
  completion, and previous-command strategies ([zsh-autosuggestions
  documentation](https://github.com/zsh-users/zsh-autosuggestions)). The plain
  history strategy is the least surprising choice here.
- Home Manager deliberately sources syntax highlighting after completion,
  aliases, and custom widgets. This matches the upstream requirement that the
  highlighter be loaded after other ZLE widgets ([zsh-syntax-highlighting
  installation guidance](https://github.com/zsh-users/zsh-syntax-highlighting/blob/master/INSTALL.md)).

The implementation adds `programs.fzf.enable = true` and
`programs.fzf.enableZshIntegration = true`.
Home Manager 26.05 installs the pinned package and injects the upstream Zsh
integration, including fuzzy `Ctrl-R`, `Ctrl-T`, and `Alt-C` behavior ([Home
Manager fzf source](https://github.com/nix-community/home-manager/blob/release-26.05/modules/programs/fzf.nix)). This is preferable to adding a separate
history-substring-search plugin because `fzf` provides a materially better
interactive search without adding a second history database or cloud sync. The
integration is the same mechanism recommended by fzf upstream ([fzf shell
integration](https://github.com/junegunn/fzf#setting-up-shell-integration)).

Do not enable Home Manager's `historySubstringSearch` at the same time. Both it
and fzf compete for history-navigation key bindings, and the repository does not
need two overlapping search interfaces.

## Keymap and shell options

Make the intended interactive model explicit:

```nix
defaultKeymap = "emacs";
setOptions = [
  "INTERACTIVE_COMMENTS"
  "NO_BEEP"
];
```

Emacs mode preserves familiar `Ctrl-A`, `Ctrl-E`, and `Ctrl-R` conventions and
matches fzf's default history binding. `INTERACTIVE_COMMENTS` lets a developer
use an unquoted `#` comment in an interactive command. `NO_BEEP` removes the
terminal bell when history or completion has no further match. Avoid
`CORRECT_ALL`, `AUTO_CD`, `NO_NOMATCH`, global aliases, or other options that
silently reinterpret typed commands.

## Aliases and functions

Keep the initial alias and function sets empty.

The user remembered having cloud-related aliases, but the read-only recovery
search found no `~/.zshrc`, `~/.zprofile`, or `~/.zlogin`; the surviving history
was effectively empty; and iCloud Drive and the inspected developer repositories
contained no recoverable Zsh alias definition. There is therefore no trustworthy
source from which to reconstruct the old alias names or commands. Guessing them
would create new behavior rather than recover existing configuration.

The local project evidence supports `git`, `gh`, `kubectl`, and `pulumi`, and
those executables are already declared. It does not support global AWS, GCP, or
Cloudflare CLI ownership: no `aws`, `gcloud`, `cloudflared`, or global
`wrangler` executable is declared in this repository. Project-local Wrangler
belongs to the project's JavaScript dependencies.

Aliases provide little benefit for infrequent or destructive infrastructure
commands and can hide important context during review or incident response. In
particular, do not alias deploy, destroy, force, reset, push, cluster switching,
credential selection, or secret-loading commands. Do not place tokens, account
IDs, hostnames, usernames, `op://` references, or resolved credentials in public
aliases or shell functions.

Add an alias only after a repeated real workflow is identified. Prefer
repository-owned commands such as `just` recipes for project workflows because
they travel with the project and can be reviewed with the code.

## Prompt and frameworks

Do not add Oh My Zsh or another shell framework. Home Manager already provides
the useful pieces directly, so a framework would add another configuration
layer and a large plugin surface without solving a current need.

Starship is a valid Home Manager-managed, cross-platform prompt, but it is not
necessary for the basic shell baseline. The current repo has not declared a
prompt requirement, theme, or status fields. Leave the prompt alone until the
base shell is activated and proven; if a richer prompt is requested later, use
Home Manager's `programs.starship` module rather than a downloaded installer or
hand-written initialization ([Home Manager Starship
source](https://github.com/nix-community/home-manager/blob/release-26.05/modules/programs/starship.nix)).

## Comparison with Wimpy's repository

Wimpy's current `wimpysworld/nix-config` at inspected commit
[`9319a38`](https://github.com/wimpysworld/nix-config/tree/9319a38dcedab8793d4c2ae395a9c3207ebbd492)
reinforces the ownership pattern, but not every one of its user-interface
choices:

- Home Manager owns its shell integrations and portable terminal tools.
- Its [fzf
  module](https://github.com/wimpysworld/nix-config/blob/9319a38dcedab8793d4c2ae395a9c3207ebbd492/home-manager/_mixins/terminal/fzf.nix)
  enables Home Manager's integration conditionally for each enabled shell. This
  supports adding Home Manager-managed fzf here.
- Its [Starship
  module](https://github.com/wimpysworld/nix-config/blob/9319a38dcedab8793d4c2ae395a9c3207ebbd492/home-manager/_mixins/terminal/starship.nix)
  is a large, personal Catppuccin prompt with many language glyphs, hostname,
  username, and path substitutions. That is a preference-heavy theme, not a
  general requirement, so it should not be copied into this minimal public
  baseline.
- Wimpy's declared default shell is Fish on both Darwin and NixOS; Zsh
  integrations are conditional and generally inactive. His user-specific
  workstation also enables Atuin with automatic synchronized history. That is a
  different product choice requiring a private encryption key and mutable cloud
  state, not evidence that this Zsh baseline should sync its history.
- His repository carries many aliases across Bash, Fish, and Zsh because it
  supports a much broader personal tool suite. Copying those aliases would add
  commands and assumptions that this repository does not install.

The transferable pattern is declarative Home Manager ownership. Fish, Atuin,
the elaborate prompt, and the alias inventory remain Wimpy's personal choices.

## Ownership boundary

- nix-darwin registers the Nix-provided Zsh as an allowed shell and selects it as
  the declared user's login shell.
- Home Manager owns Zsh configuration, completion, plugins, `fzf`, the mise
  activation hook, aliases/functions, and the path and policy for history.
- Zsh owns the mutable history file contents at runtime. Nix must not materialize
  that file in the Nix store or overwrite it during activation.
- mise owns mutable Node runtime selection and activation after Home Manager has
  initialized the shell.
- 1Password and provider CLIs own credentials and authentication sessions. The
  shell configuration contains neither secret values nor synced session state.

This boundary keeps the configuration rebuildable while correctly excluding
history, credentials, tokens, and login sessions from the public rebuildable
state.
