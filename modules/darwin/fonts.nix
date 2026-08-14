{ pkgs, ... }:
{
  # Install the patched monospaced family system-wide so native macOS apps,
  # including Ghostty, can resolve both JetBrains Mono and Starship's glyphs.
  fonts.packages = [ pkgs.nerd-fonts.jetbrains-mono ];
}
