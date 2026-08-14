{ local, ... }:
{
  # Passwordless sudo for EXACTLY ONE command: activating this configuration.
  #
  # Why: every rebuild raised a password dialog, which made agent-driven
  # activation stall on a human at the machine (requested removed 2026-08-14).
  #
  # The tradeoff, stated plainly: this account's darwin-rebuild applies a
  # configuration the same account can edit, so NOPASSWD here is
  # root-equivalent for the account. The password prompt was never a real
  # boundary against that — the account already owns the flake — it was only
  # a consent tap. The consent trail is the git history instead: the
  # nix-only-guard hook forces every machine change through this repository,
  # and activation without a declared change is a no-op.
  #
  # Scope: the stable /run/current-system symlink path only, so ad-hoc sudo
  # for anything else still prompts. SETENV because scripts/rebuild.sh passes
  # NIX_CONFIG_LOCAL via --preserve-env — it must NOT wrap the command in
  # `env`, or sudoers matches `env` (not darwin-rebuild) and prompts anyway,
  # which is exactly what the first version of this rule got wrong. The FIRST switch on a wiped machine
  # (before any generation exists) still asks for the password once — the
  # rule cannot predate the system it is part of.
  security.sudo.extraConfig = ''
    ${local.user} ALL=(root) NOPASSWD:SETENV: /run/current-system/sw/bin/darwin-rebuild
  '';
}
