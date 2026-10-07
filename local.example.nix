{
  # Copy this file to the ignored local.nix and replace every placeholder.
  user = "replace-me";
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
    # Reference only: the matching private key is read through Connect.
    signingKeyReference = "op://Automation/Git signing/private key?ssh-format=openssh";
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

  # The vault holding the "nix-config local.nix" Secure Note that
  # scripts/rebuild.sh saves through Connect. Read from here rather than
  # hard-coded, which keeps a private vault name out of the tracked scripts;
  # scripts/setup-mac.sh finds the note by title in any vault it can see.
  onePassword.vault = "ExampleVault";

  # The 1Password Connect server every 1Password read on this Mac goes
  # through, and the item holding its access token. Names, not values: the
  # token itself lives only in the 0600 Connect env file the setup writes.
  # Prefer item IDs over titles; IDs survive retitling.
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
  # modules/home/downloads.nix creates local directories, never mountpoints.
  #
  # Choose an always-available location for reliable downloads: the policy
  # names one static destination, with no fallback while a volume is offline.
  # A path under /Volumes requires its actual volume to be mounted. Activation
  # leaves unavailable volumes untouched and continues setup; it does not
  # create a local substitute, change permissions, or mount a share itself.
  # SMB mounting belongs to network-shares.nix, after Keychain setup.
  downloadsDirectory = "/Volumes/ExampleDisk/Downloads";

  # Where package and tool caches go (Bun, NuGet, Playwright, Puppeteer, uv,
  # Homebrew downloads, Cargo, rustup, and XDG_CACHE_HOME).
  # modules/home/caches.nix creates the subdirectories and exports the
  # variables. Same rule as downloads: a path that is always present. Omit or
  # set to null to keep every default.
  cacheDirectory = "/Volumes/ExampleDisk/Caches";

  # Chrome profile DIRECTORY (Default, "Profile 3", ...) whose signed-in X and
  # Reddit sessions Agent-Reach's backends read (modules/home/agent-reach).
  # Names are under "profile.info_cache" in Chrome's Local State file. Null
  # lets each backend take the first profile with cookies, Default first.
  agentReach.chromeProfile = null;

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
