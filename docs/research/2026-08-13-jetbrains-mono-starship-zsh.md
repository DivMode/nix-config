# JetBrains Mono, cmux, Starship, and Zsh on macOS

Researched 2026-08-13 against the repository's declared 26.05 branches. The
inputs become pinned only after a `flake.lock` is generated. This
report interprets “Jeff Brain operator mono” as **JetBrains Mono**. Operator
Mono is a different commercial typeface and is not what the Nix attributes
below install.

## Recommendation

1. Install `pkgs.nerd-fonts.jetbrains-mono` with nix-darwin's
   `fonts.packages`, not Homebrew and not a download script.
2. Select `JetBrainsMono Nerd Font Mono` in cmux's Ghostty-compatible config at
   `~/.config/ghostty/config`. Let Home Manager own that file and reload cmux
   after a rebuild.
3. Install and configure Starship with Home Manager. Use Starship's official
   `nerd-font-symbols` preset and otherwise stay close to its useful defaults.
4. Do not install Oh My Zsh. Home Manager already provides the required shell
   features directly, and Oh My Zsh's `sudo` plugin conflicts with the declared
   Caps Lock to Escape behavior.
5. Keep the repository's Nix-provided Zsh as the login shell. Do not switch to
   C shell (`csh`/`tcsh`).

This gives each layer one owner: nix-darwin installs system fonts and registers
the login shell; Home Manager owns the user prompt, Zsh configuration, plugins,
and cmux terminal-rendering config; cmux owns mutable sessions and runtime UI
state.

## 1. JetBrains Mono through Nix

The exact attributes on the declared Nixpkgs 26.05 branch are:

```nix
pkgs.jetbrains-mono
pkgs.nerd-fonts.jetbrains-mono
```

The first is upstream JetBrains Mono 2.304. The second is the Nerd Fonts 3.4.0
patched family based on JetBrains Mono 2.304. These names were verified in the
actual declared branch: the [JetBrains Mono package expression][nixpkgs-jbm], the
[Nerd Fonts attribute generator][nixpkgs-nf], and the
[26.05 Nerd Fonts manifest entry][nixpkgs-nf-manifest]. The manifest converts
the cask name `jetbrains-mono` directly to the attribute
`nerd-fonts.jetbrains-mono`.

Use only `pkgs.nerd-fonts.jetbrains-mono` for this workstation. Starship's Nerd
Font symbol preset uses patched icon glyphs; installing both variants is
redundant and makes font selection less obvious. Nerd Fonts' own JetBrains Mono
documentation recommends the `Nerd Font Mono` family for terminals that expect
strictly monospaced glyphs and confirms that current Mono variants retain
ligatures ([Nerd Fonts JetBrains Mono README][nf-jbm]). The exact cmux family
string should therefore be:

```text
JetBrainsMono Nerd Font Mono
```

On macOS, the correct system declaration is:

```nix
fonts.packages = [ pkgs.nerd-fonts.jetbrains-mono ];
```

nix-darwin 26.05 copies declared fonts into `/Library/Fonts/Nix Fonts` during
system activation and reconciles that dedicated directory. Its source
explicitly marks both `fonts.enableFontDir` and `fonts.fontDir.enable` as
removed: there is **no** macOS `fontDir` switch to add, and it is not required
to install fonts ([nix-darwin fonts module][darwin-fonts]). This belongs in a
Darwin module rather than `home.packages`, because cmux is a native macOS app
and should see a normally registered system font.

Wimpy's current repository uses the same system-level pattern—Nerd Fonts are
listed under nix-darwin `fonts.packages`—although it chooses Fira rather than
JetBrains Mono ([Wimpy fonts module][wimpy-fonts]). The reusable practice is the
ownership mechanism, not the particular font list.

## 2. Declaring the font in cmux

cmux is Ghostty-based and officially reads terminal-rendering settings from,
in order:

1. `~/.config/ghostty/config`
2. `~/Library/Application Support/com.mitchellh.ghostty/config`

Its official example uses Ghostty syntax such as `font-family = SF Mono` and
`font-size = 13` ([cmux configuration documentation][cmux-config]). The desired
Home Manager-managed file can therefore begin with:

```text
font-family = JetBrainsMono Nerd Font Mono
font-size = 14
```

`14` is a reasonable Retina-display baseline, but it is a preference rather
than a technical requirement. It can be changed in Nix after seeing it in the
real terminal.

cmux reloads Ghostty configuration with `Cmd+Shift+,` or `cmux reload-config`;
the application does not need to be restarted. Home Manager should own the
file because the user explicitly wants the font to be reproducible. A managed
file will be a read-only Nix-store-backed symlink, so changes should be made in
Nix and rebuilt, not edited through an application UI. The project's existing
collision rule must reject a pre-existing unmanaged file rather than silently
replace it.

Do not confuse this file with `~/.config/cmux/cmux.json`. cmux's official docs
reserve that JSON-with-comments file for cmux-owned application settings,
shortcuts, actions, and workspace behavior; terminal font and colors remain in
the Ghostty config. Mutable session snapshots live under Application Support
and should not be put in Nix. At the time of inspection, neither supported
Ghostty config path nor `~/.config/cmux/cmux.json` exists on this Mac, so there
is no existing terminal font declaration to preserve.

## 3. Starship through Home Manager

Starship is a cross-shell prompt, not a shell and not a terminal theme. Home
Manager 26.05 has a first-class module that installs the package, writes
`$XDG_CONFIG_HOME/starship.toml`, and inserts the correct Zsh initialization
when `enableZshIntegration` is enabled
([Home Manager Starship source][hm-starship]). It also supports merging official
Starship preset files before explicit settings.

A restrained useful declaration is:

```nix
programs.starship = {
  enable = true;
  enableZshIntegration = true;
  presets = [ "nerd-font-symbols" ];
  settings = {
    add_newline = false;
  };
};
```

The official Nerd Font Symbols preset changes module symbols while preserving
Starship's standard layout ([Starship preset][starship-nerd-preset]). Starship's
defaults already show contextual directory, Git, language/runtime, Nix-shell,
command-duration, jobs, and status information only when relevant, so a large
copied prompt is unnecessary. `add_newline = false` keeps the prompt compact.
Add further fields only after using this baseline.

Wimpy also enables Starship through Home Manager and enables its integration
for whichever shell is active ([Wimpy Starship module][wimpy-starship]). His
large Catppuccin powerline prompt, dozens of glyph substitutions, always-shown
hostname/username, and broad language list are personal presentation choices.
Copying them would make this public baseline noisy and harder to maintain.

## 4. Oh My Zsh: framework, not the theme we need

Oh My Zsh is a framework layered on Zsh; its plugins can add aliases,
completion, and functions, and its themes set the shell prompt
([Oh My Zsh FAQ][omz-faq]). Starship already owns the prompt. Oh My Zsh's own
theme documentation says to set its theme to blank when no Oh My Zsh theme is
wanted ([Oh My Zsh themes][omz-themes]). Therefore never enable an Oh My Zsh
theme alongside Starship.

The current Home Manager configuration already owns completion,
`zsh-autosuggestions`, `zsh-syntax-highlighting`, and fzf integration. Enabling
the same functionality again through Oh My Zsh plugins would duplicate widget
hooks, completion initialization, key bindings, and aliases. Home Manager's
Zsh source specifically skips its own `compinit` when Oh My Zsh is enabled and
loads syntax highlighting after other widgets, demonstrating that the layers
can coexist but must have non-overlapping ownership
([Home Manager Zsh source][hm-zsh]).

The selected baseline is Starship plus the existing Home Manager-native Zsh
features without Oh My Zsh. A broader comparison of popular public Nix
configurations confirmed that this is a common approach and avoids overlapping
plugin ownership.

If Oh My Zsh is reconsidered later for its bundled helpers, use
Home Manager's `programs.zsh.oh-my-zsh` module—never its curl installer—and:

- keep `theme = ""` so Starship is the only prompt owner;
- do not enable `fzf`, `zsh-autosuggestions`, or syntax-highlighting plugins;
- use only the reviewed `sudo`, `colored-man-pages`, and `extract` helpers;
- exclude `git`, whose shorthand includes force-push, hard-reset, and
  destructive-clean commands;
- let the Nix package declared by the flake control upgrades rather than mutable
  self-update.

The Home Manager module installs the Nix package, points `ZSH` to the immutable
store path, keeps cache data in the XDG cache directory, and declares its plugin
and theme options ([Home Manager Oh My Zsh source][hm-omz]).

## 5. Apple Zsh, Nix Zsh, and C shell

The live account currently reports `/bin/zsh` as its login shell, and the live
binary is Apple Zsh 5.9. That is expected because this Nix configuration has not
been activated.

The repository's intended arrangement is already correct:

```nix
programs.zsh.enable = true;             # nix-darwin system integration
environment.shells = [ pkgs.zsh ];      # allowed login shell
users.users.${local.user}.shell = pkgs.zsh;
programs.zsh.package = pkgs.zsh;        # Home Manager user config
```

nix-darwin's `environment.shells` module writes Nix-provided shells into
`/etc/shells`, while preserving macOS's standard shells
([nix-darwin shells source][darwin-shells]). Its user option changes the
account's declared shell, and its Zsh module installs/configures the Nixpkgs
binary ([nix-darwin Zsh source][darwin-zsh]). Home Manager then generates the
user-level Zsh files and plugins for that same package. This avoids an
Apple/Nix version split and makes the selected shell version part of the system
generation; the exact version becomes reproducible once the flake is locked.

Do not install Zsh with Homebrew; Nix already owns it. Do not use Apple's
`/bin/zsh` as the final declared shell if reproducibility is the goal. Also do
not switch to C shell: `csh`/`tcsh` is a different shell, does not run Zsh or
Oh My Zsh configuration, and would defeat the requested setup. If “CSH” was a
speech-to-text rendering of “Zsh,” the answer is: use the Nix-provided Zsh
already declared by this repository.

## Implementation boundary

These findings imply three small declarative changes:

- nix-darwin: add `fonts.packages = [ pkgs.nerd-fonts.jetbrains-mono ];`
- Home Manager: own `~/.config/ghostty/config` with the font family and size
- Home Manager: enable Starship with the Nerd Font Symbols preset
Do not install fonts or Starship through Homebrew, do not run the Oh My Zsh
installer, and do not copy mutable cmux sessions into Nix.

[nixpkgs-jbm]: https://github.com/NixOS/nixpkgs/blob/nixos-26.05/pkgs/by-name/je/jetbrains-mono/package.nix
[nixpkgs-nf]: https://github.com/NixOS/nixpkgs/blob/nixos-26.05/pkgs/data/fonts/nerd-fonts/default.nix
[nixpkgs-nf-manifest]: https://github.com/NixOS/nixpkgs/blob/nixos-26.05/pkgs/data/fonts/nerd-fonts/manifests/fonts.json
[darwin-fonts]: https://github.com/nix-darwin/nix-darwin/blob/nix-darwin-26.05/modules/fonts/default.nix
[nf-jbm]: https://github.com/ryanoasis/nerd-fonts/blob/master/patched-fonts/JetBrainsMono/README.md
[cmux-config]: https://cmux.com/docs/configuration
[hm-starship]: https://github.com/nix-community/home-manager/blob/release-26.05/modules/programs/starship.nix
[starship-nerd-preset]: https://starship.rs/presets/nerd-font
[wimpy-fonts]: https://github.com/wimpysworld/nix-config/blob/main/darwin/_mixins/features/fonts/default.nix
[wimpy-starship]: https://github.com/wimpysworld/nix-config/blob/main/home-manager/_mixins/terminal/starship.nix
[omz-faq]: https://github.com/ohmyzsh/ohmyzsh/wiki/FAQ
[omz-themes]: https://github.com/ohmyzsh/ohmyzsh/wiki/Themes
[hm-zsh]: https://github.com/nix-community/home-manager/blob/release-26.05/modules/programs/zsh/default.nix
[hm-omz]: https://github.com/nix-community/home-manager/blob/release-26.05/modules/programs/zsh/plugins/oh-my-zsh.nix
[darwin-shells]: https://github.com/nix-darwin/nix-darwin/blob/nix-darwin-26.05/modules/system/shells.nix
[darwin-zsh]: https://github.com/nix-darwin/nix-darwin/blob/nix-darwin-26.05/modules/programs/zsh/default.nix
