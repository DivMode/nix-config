{
  # Copy this file to the ignored local.nix and replace every placeholder.
  user = "replace-me";
  hostName = "example-mac";
  system = "aarch64-darwin";
  homeDirectory = "/Users/replace-me";

  # Git identity is machine-local so the public repository stays generic.
  # The email still appears in commits and the evaluated Nix store; it is not
  # a secret. The signing key is an SSH public key, never a private key.
  git = {
    name = "replace-me";
    email = "replace-me@example.invalid";
    # Structurally valid public-only placeholder so generic flake checks work.
    signingKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
  };

  # 1Password item IDs are local metadata, not secret values. IDs avoid
  # publishing private item or vault names in this reusable repository.
  onePassword.sshAgentKeyIds = [ "aaaaaaaaaaaaaaaaaaaaaaaaaa" ];
}
