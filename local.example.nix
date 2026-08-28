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

  # Project directories. Each attribute name becomes a Zsh function that changes
  # into the directory and starts Claude Code there, plus an entry in the `p`
  # jump function. Private repository names belong here rather than in the
  # public modules, which is why this file is ignored by Git.
  #
  # The name must be a valid shell function name and must not shadow a builtin;
  # modules/home/projects.nix asserts both at evaluation time.
  projects = {
    example-project = "/Users/replace-me/Developer/example-project";
  };

  # Extra strings scripts/check-private-names.sh must keep out of this public
  # repository. It already derives a denylist from the fields above — the user,
  # the host, the home directory, the Git identity, every project name and path,
  # and every vault named below — so this is only for anything else private that
  # could be typed into a comment by mistake.
  privateTerms = [ ];

  # The opposite of privateTerms: terms the guard's derivation picks up from the
  # fields above that are NOT actually private, and so may appear in tracked
  # files. Use it only for names that would mean nothing to a stranger reading
  # this public repository — a generic vault name, say. Anything identifying a
  # person, employer, client, host, or private path belongs in privateTerms.
  publicTerms = [ ];

  # 1Password item IDs are local metadata, not secret values. IDs avoid
  # publishing private item or vault names in this reusable repository.
  onePassword.sshAgentKeyIds = [ "aaaaaaaaaaaaaaaaaaaaaaaaaa" ];

  # The vault holding this host's local.nix Document backup. scripts/rebuild.sh
  # reads it from here rather than hard-coding it, which is what keeps a private
  # vault name out of the tracked scripts; scripts/setup-mac.sh asks for it once
  # on a wiped machine, because local.nix is the file it is restoring.
  onePassword.vault = "ExampleVault";

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

  # Where browser downloads land. modules/darwin/chrome.nix declares it as a
  # mandatory Chrome policy, modules/darwin/dock.nix pins it as a stack, and
  # modules/home/downloads.nix creates it.
  #
  # It must be a path that is ALWAYS present. Chrome's DownloadDirectory policy
  # takes one static string, read at launch, with no fallback — so a path that
  # comes and goes, an SMB mount or a disk that is sometimes unplugged, aims
  # every download made while it is away at somewhere that does not exist and
  # that Chrome cannot create.
  downloadsDirectory = "/Volumes/ExampleDisk/Downloads";

  # SMB shares mounted at login by modules/home/network-shares.nix. Leave
  # `mounts` empty to disable the module entirely.
  #
  # The PASSWORD IS NOT HERE and must never be. It lives in the login Keychain.
  # This file names only the server and the account — the two halves of the
  # Keychain lookup key.
  networkShares = {
    server = "fileserver.example.invalid";
    account = "replace-me";
    mounts = [ ];
    # Optional op:// reference used ONLY to seed the login Keychain on a machine
    # that has no entry yet. A reference, never a password: any literal value in
    # a Nix option is copied into the world-readable store.
    passwordReference = null;
  };
}
