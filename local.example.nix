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

  # Where the service-account token is read from, as an op:// reference. This
  # is a NAME, not a value; the token itself never appears in Nix. Prefer the
  # item ID over its title — op rejects a reference containing '(' outright,
  # and IDs survive retitling.
  onePassword.serviceAccountReference = "op://ExampleVault/aaaaaaaaaaaaaaaaaaaaaaaaaa/token";

  # A 1Password Connect server, if one is reachable. Read by the deploy path
  # only — never exported to shells, because with OP_CONNECT_HOST set the op
  # CLI refuses every non-JSON output format and `op item get --fields` breaks.
  onePassword.connectReference = "op://ExampleVault/bbbbbbbbbbbbbbbbbbbbbbbbbb/access-token";
  onePassword.connectHost = "http://198.51.100.10:8091";

  # AWS profiles resolved from 1Password at call time via credential_process.
  # `item` is a TITLE passed as an argument to `op item get`, so punctuation
  # that an op:// reference would reject is fine here. No key is stored.
  onePassword.awsProfiles = {
    example-dev = {
      vault = "ExampleVault";
      item = "Example AWS Access Key (Dev)";
      region = "us-west-2";
    };
  };
}
