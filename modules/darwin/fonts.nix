{ pkgs, ... }:
{
  # Install the patched monospaced family system-wide so native macOS apps,
  # including cmux, can resolve both JetBrains Mono and Starship's icon glyphs.
  fonts.packages = [ pkgs.nerd-fonts.jetbrains-mono ];
}
