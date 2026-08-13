# Oh My Zsh in popular Nix configurations

Date: 2026-08-13

Question: Does this Mac configuration need Oh My Zsh, and do prominent Nix
configurations use it?

## Answer

Oh My Zsh is popular, but it is not a requirement for a polished Zsh setup and
it is not the prevailing pattern among the popular Nix configurations inspected
here. It is a framework that initializes Zsh, loads a broad set of framework
libraries, and provides a catalog of opt-in themes and plugins. It is not Zsh,
Starship, completion, autosuggestions, syntax highlighting, or `fzf`.

This repository already gives those features to their narrowest owner:

- Home Manager owns Zsh, completion, history, and keymap policy;
- Home Manager's dedicated modules own autosuggestions, syntax highlighting,
  and `fzf` integration;
- Starship exclusively owns the prompt;
- mise owns development-runtime activation.

The current Oh My Zsh declaration therefore contributes only its framework
defaults plus the three selected plugins: `sudo`, `colored-man-pages`, and
`extract`. That is not enough benefit to justify keeping another initialization
layer. The recommendation is to remove Oh My Zsh and retain the existing
Home Manager-native features. If archive extraction is wanted, declare a
standalone tool or a small reviewed function explicitly. Colored manual pages
can likewise be expressed directly. Do not keep an entire framework solely for
those two conveniences.

The `sudo` plugin is specifically a poor fit: it binds double Escape in every
standard keymap. In this Mac configuration, tapping Caps Lock emits Escape, so
double-tapping Caps Lock rewrites the current command buffer to add or remove
`sudo`. It does not execute the command, but it is hidden keyboard behavior that
we did not otherwise ask for.

## Direct evidence that some Nix users install it

There is real, current evidence; it just does not establish a best practice.
Star counts below are GitHub's API values observed on 2026-08-13 and are a
popularity signal, not a measurement of engineering quality.

| Repository | Stars | Direct source evidence | What it actually uses Oh My Zsh for |
| --- | ---: | --- | --- |
| [MatthiasBenaets/nix-config](https://github.com/MatthiasBenaets/nix-config) | 742 | [Home Manager enables it](https://github.com/MatthiasBenaets/nix-config/blob/f52d46f5516016dff8da01362e16204a45cdcfa6/modules/programs/zsh/zsh.nix#L61-L74); the same file also contains a [NixOS-level declaration](https://github.com/MatthiasBenaets/nix-config/blob/f52d46f5516016dff8da01362e16204a45cdcfa6/modules/programs/zsh/zsh.nix#L10-L21) | Home Manager uses its `macos` plugin. The NixOS variant uses a broader plugin set and the `agnoster` theme. |
| [EmergentMind/nix-config](https://github.com/EmergentMind/nix-config) | 640 | [Home Manager Zsh module enables it](https://github.com/EmergentMind/nix-config/blob/5f8b7777b9fc094696e7aa9d398f9d0dba67eeec/home/common/core/zsh/default.nix#L30-L63) | The `git` plugin and framework completion settings. It separately enables Home Manager completion, autosuggestions, syntax highlighting, and other Zsh plugins. Notably, it comments out `sudo` because Escape shares a remapped key. |
| [basnijholt/dotfiles](https://github.com/basnijholt/dotfiles) | 145 | [Zsh startup loads Oh My Zsh](https://github.com/basnijholt/dotfiles/blob/9f9ec965e8650eeeb77c43c2ca7bc3d2dd1e7e68/configs/shell/70_zsh_plugins.sh#L20-L34) and the [README explains the choice](https://github.com/basnijholt/dotfiles/blob/9f9ec965e8650eeeb77c43c2ca7bc3d2dd1e7e68/README.md#L37-L47) | `git`, `sudo`, `iterm2`, `uv`, and `docker-compose`, plus framework keybindings and a fallback custom theme. The author explicitly calls it "bloated and slow" and disables its updater for speed. This is a hybrid nix-darwin/dotfiles setup, not Home Manager ownership of Oh My Zsh. |

These are legitimate examples, but none resembles our proposed use. They
consume more of Oh My Zsh's plugin surface. Our configuration disables its
theme because Starship already owns the prompt, while Home Manager already owns
the other major interactive features.

## Direct evidence from more popular configurations that do not use it

The following current repositories provide useful counterexamples:

| Repository | Stars | Direct source evidence | Shell approach |
| --- | ---: | --- | --- |
| [mitchellh/nixos-config](https://github.com/mitchellh/nixos-config) | 3,071 | [Home Manager config enables Fish and its plugins](https://github.com/mitchellh/nixos-config/blob/main/users/mitchellh/home-manager.nix#L167-L186); [macOS login shell is Fish](https://github.com/mitchellh/nixos-config/blob/main/users/mitchellh/darwin.nix#L29-L34) | Fish with focused plugins; no Oh My Zsh. |
| [ryan4yin/nix-config](https://github.com/ryan4yin/nix-config) | 2,014 | [Home Manager enables plain Zsh](https://github.com/ryan4yin/nix-config/blob/88e916b63e7b5f1af4ddb80fbef1b084d13816b0/home/darwin/shell.nix#L31-L39) and a [separate Starship module](https://github.com/ryan4yin/nix-config/blob/88e916b63e7b5f1af4ddb80fbef1b084d13816b0/home/base/core/starship.nix#L1-L28) | Home Manager Zsh plus Starship; no framework. |
| [joshsymonds/nix-config](https://github.com/joshsymonds/nix-config) | 833 | [Home Manager directly enables completion, history search, syntax highlighting, and autosuggestions](https://github.com/joshsymonds/nix-config/blob/90765ce4f713bff6dba035f565795497f677c80a/home-manager/zsh/default.nix#L225-L246), then [loads Starship directly](https://github.com/joshsymonds/nix-config/blob/90765ce4f713bff6dba035f565795497f677c80a/home-manager/zsh/default.nix#L518-L525) | Fine-grained Home Manager modules; no Oh My Zsh. |
| [wimpysworld/nix-config](https://github.com/wimpysworld/nix-config) | 709 | [The declared user shell is Fish](https://github.com/wimpysworld/nix-config/blob/9319a38dcedab8793d4c2ae395a9c3207ebbd492/nixos/_mixins/users/default.nix#L15-L28) and [Starship integration is separately managed](https://github.com/wimpysworld/nix-config/blob/9319a38dcedab8793d4c2ae395a9c3207ebbd492/home-manager/_mixins/terminal/starship.nix#L1-L15) | Fish plus Starship. Wimpy's repository does not enable Oh My Zsh. |
| [lovesegfault/nix-config](https://github.com/lovesegfault/nix-config) | 459 | [Home Manager Zsh module](https://github.com/lovesegfault/nix-config/blob/43c6688f9ff9c1ba3daa898cec55754c34bdb415/modules/home/zsh.nix#L8-L51) | Direct Nix packages for completions, vi mode, fast syntax highlighting, autopair, and history search; no framework. |
| [jwiegley/nix-config](https://github.com/jwiegley/nix-config) | 458 | [Home Manager Zsh module](https://github.com/jwiegley/nix-config/blob/431e3e9690028e28fb1a452c08fdba697911efe4/config/zsh.nix#L22-L78) | Native Home Manager Zsh settings and an explicit prompt; no Oh My Zsh. |
| [AlexNabokikh/nix-config](https://github.com/AlexNabokikh/nix-config) | 415 | [Small Home Manager Zsh module](https://github.com/AlexNabokikh/nix-config/blob/3d21aa8444ceb1dcfb749cb1f55ef1bfd841a762/modules/programs/zsh.nix#L1-L27) plus [separate Starship module](https://github.com/AlexNabokikh/nix-config/blob/3d21aa8444ceb1dcfb749cb1f55ef1bfd841a762/modules/programs/starship.nix#L1-L28) | Plain Zsh plus Starship; no Oh My Zsh. |

A broad source search across popular `nix-config`, `nixos-config`, and dotfiles
repositories on 2026-08-13 found both approaches. Oh My Zsh appeared in the two
well-starred Nix configurations above, while several more popular repositories
used Fish or composed Zsh features directly. This is not a census of every Nix
configuration, but it directly contradicts the claim that serious Nix users
generally need the framework.

## What the framework and our three plugins do

Home Manager's [official Oh My Zsh module](https://github.com/nix-community/home-manager/blob/d4fd24667c8cbef124bb70a20380cab75ec8474d/modules/programs/zsh/plugins/oh-my-zsh.nix#L68-L98)
installs the Nix package, points `ZSH` at the Nix store, creates a writable cache,
sets the chosen plugin/theme variables, and sources `oh-my-zsh.sh`. This is the
correct declarative way to install the framework if it is wanted; it does not
make the framework necessary.

Sourcing the framework does more than load the selected plugins. The official
[initializer](https://github.com/ohmyzsh/ohmyzsh/blob/b54a71977574cfcf659cc2f15a5e6422f17a8da7/oh-my-zsh.sh#L67-L220)
constructs completion paths, runs `compinit`, compiles completion state, and
loads every stock `lib/*.zsh` file before loading the selected plugins. That
overlaps conceptually with a configuration where Home Manager already owns
completion and keymap behavior.

The selected plugins are narrow:

- [`sudo`](https://github.com/ohmyzsh/ohmyzsh/blob/b54a71977574cfcf659cc2f15a5e6422f17a8da7/plugins/sudo/sudo.plugin.zsh#L25-L94)
  binds Escape twice and toggles a `sudo`/`sudo -e` prefix in the command
  buffer. It does not run the command automatically.
- [`colored-man-pages`](https://github.com/ohmyzsh/ohmyzsh/blob/b54a71977574cfcf659cc2f15a5e6422f17a8da7/plugins/colored-man-pages/colored-man-pages.plugin.zsh#L1-L47)
  wraps `man`, `dman`, and `debman` and supplies color-related `LESS_TERMCAP_*`
  values.
- [`extract`](https://github.com/ohmyzsh/ohmyzsh/blob/b54a71977574cfcf659cc2f15a5e6422f17a8da7/plugins/extract/extract.plugin.zsh#L1-L148)
  adds `extract` and alias `x`, dispatching archive formats to external tools.
  Its optional `-r`/`--remove` switch deletes the source archive after a
  successful extraction; default extraction retains it.

None of those plugins supplies Starship, autosuggestions, syntax highlighting,
or fuzzy history/file search. Those remain separate programs in both Oh My Zsh
examples above.

## Decision for this repository

Remove `programs.zsh.oh-my-zsh` rather than retaining it for two minor helpers
and an undesirable double-Escape binding. Continue using Nix's Zsh package and
Home Manager's dedicated modules. This stays fully declarative and follows the
same fine-grained pattern visible in several more popular Nix configurations.

No implementation was changed or activated as part of this research.
