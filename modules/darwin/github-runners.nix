{
  config,
  lib,
  local,
  pkgs,
  ...
}:
let
  inherit (lib) escapeShellArg;

  # Activation puts GNU coreutils ahead of /usr/bin; name them so `stat`
  # cannot silently mean the BSD one.
  coreutils = "${pkgs.coreutils}/bin";

  # Self-hosted GitHub Actions runners for one private repository, declared in
  # local.nix (`githubRunners`) because the repository's name is private.
  # Absent there, nothing here is configured.
  cfg = local.githubRunners or null;

  names = map (index: "mac-${toString index}") (lib.range 1 cfg.count);

  # nix-darwin manages this user and group when a runner sets neither `user`
  # nor `group` (modules/services/github-runner/service.nix in the pinned
  # nix-darwin). Every runner shares it. It is not the owner, so a job cannot
  # read the owner's home directory, where the agent clients' state, the
  # Connect environment and the Git signer live. Nor can it reach the external
  # data volume, even though that volume is mounted `noowners`: macOS privacy
  # protection refuses a background daemon there (measured 2026-10-31, a
  # work directory on it failed with `find: ...: Operation not permitted`),
  # and this repository never automates a privacy grant. So the runners keep
  # the module's default work directories on the system volume.
  user = "_github-runner";

  # The registration token. A job could read it, which is harmless: GitHub
  # expires a registration token an hour after issuing it, it only registers
  # runners, and nix-config-github-runners-register empties this file once
  # every runner is online. The runner's lasting credential is the key
  # `config.sh` writes into its own state directory. The pinned module passes
  # the token to `config.sh` as `--token`, so while a runner registers it is in
  # that process's arguments; the same one-hour limit bounds that, and this
  # Mac has one human account.
  #
  # The owner writes it (the registration command runs as the owner, after
  # activation); the runner user reads it through the group. It sits outside
  # every runner's state directory because those are mode 750 and owned by
  # the runner user.
  tokenFile = "/var/lib/github-runners/registration-token";

  # The work directory the pinned module gives a runner with `workDir = null`
  # (`mkWorkDir` in its service.nix), which also creates it.
  defaultWorkDir = name: "/private/var/lib/github-runners/_work/${name}";

  # Runners in local.nix order, as `NAME` lines, for the registration command.
  runnerList = pkgs.writeText "github-runners" (lib.concatLines names);

  register = pkgs.writeShellApplication {
    name = "nix-config-github-runners-register";
    runtimeInputs = [ pkgs.jq ];
    text = ''
      # Registers any declared runner GitHub does not list as online, then
      # waits until every one is. Runs as the owner (scripts/rebuild.sh after
      # activation), because only the owner's `gh` login may issue a
      # registration token; that token is stored in 1Password through
      # Connect and written to the file the runners read.
      repository=${escapeShellArg cfg.repository}
      tokenFile=${escapeShellArg tokenFile}
      vault=${escapeShellArg local.onePassword.vault}
      title="GitHub Actions runner registration token"
      connectItem="/etc/profiles/per-user/$(id -un)/bin/nix-config-connect-item"
      mapfile -t declared < ${runnerList}

      # Errexit does not apply inside `$(not_online)`, so a failed listing
      # must return non-zero itself; the caller's assignment then stops the
      # script instead of reading every runner as missing.
      not_online() {
        local listed
        listed=$(gh api --paginate "repos/$repository/actions/runners" \
          --jq '.runners[] | select(.status == "online") | .name') || return 1
        local name
        for name in "''${declared[@]}"; do
          grep -qxF -- "$name" <<<"$listed" || printf '%s\n' "$name"
        done
      }

      missing=$(not_online)
      if [[ -z "$missing" ]]; then
        # Nothing to register: the stale token no longer needs to exist.
        if [[ -s "$tokenFile" ]]; then
          : > "$tokenFile"
        fi
        echo "all ''${#declared[@]} runners are online"
        exit 0
      fi
      echo "registering: $(tr '\n' ' ' <<<"$missing")"

      # nix-config-connect-item refuses an item file that is not mode 0600.
      umask 077
      scratch=$(mktemp -d)
      trap 'rm -r -- "$scratch"' EXIT
      gh api --method POST "repos/$repository/actions/runners/registration-token" \
        > "$scratch/response.json"
      jq '{
        category: "API_CREDENTIAL",
        fields: [
          {id: "credential", label: "credential", type: "CONCEALED", value: .token},
          {label: "expires_at", type: "STRING", value: .expires_at}
        ]
      }' "$scratch/response.json" > "$scratch/item.json"
      "$connectItem" put "$vault" "$title" "$scratch/item.json" >/dev/null
      jq -j .token "$scratch/response.json" > "$tokenFile"

      # launchd restarts each runner every 30 s until it is online
      # (KeepAlive), and a runner without `.runner` configures itself first.
      for _ in $(seq 60); do
        missing=$(not_online)
        if [[ -z "$missing" ]]; then
          : > "$tokenFile"
          echo "all ''${#declared[@]} runners are online"
          exit 0
        fi
        sleep 5
      done
      echo "error: not online after 5 minutes: $(tr '\n' ' ' <<<"$missing")" >&2
      echo "see /var/log/github-runners/<name>/launchd-stderr.log" >&2
      # Not recovered automatically: GitHub deletes a runner that has been
      # offline for 14 days, but its local `.runner` remains, so the module
      # never configures it again. Only root can remove that state
      # (/var/lib/github-runners/<name>/.runner and .credentials*); the next
      # start then registers it with the token written above.
      exit 1
    '';
  };
in
lib.mkIf (cfg != null) {
  services.github-runners = lib.genAttrs names (name: {
    enable = true;
    url = "https://github.com/${cfg.repository}";
    inherit tokenFile;
    # A runner whose state was lost registers again under the same name.
    replace = true;
    # The pinned module writes `KeepAlive = { Crashed = false; } // mkIf
    # cfg.ephemeral { ... }`, and `//` keeps the mkIf wrapper, so a
    # non-ephemeral runner's plist has no KeepAlive at all (evaluated
    # 2026-10-31: `KeepAlive = null`) and a runner that exits, or fails to
    # register, stays stopped. Restart it on every exit, at most every 30 s
    # (the module's ThrottleInterval).
    serviceOverrides.KeepAlive = true;
  });

  # The module's PATH holds only what `actions/checkout` needs. Jobs also run
  # the system tools a macOS user has (curl, unzip, security, xcrun).
  # Jobs run below the owner's apps (`nice` 10, the same as `cpu-lock run`):
  # they still take every idle core, but four concurrent database gates once
  # put load at 62 on 30 cores and lagged the desktop (2026-11-03). Every job
  # process inherits the listener's priority.
  launchd.daemons = lib.genAttrs (map (name: "github-runner-${name}") names) (_: {
    serviceConfig.Nice = 10;
    path = lib.mkAfter [
      "/usr/bin"
      "/bin"
      "/usr/sbin"
      "/sbin"
    ];
  });

  environment.systemPackages = [ register ];

  # The module's state and log directories are mode 750 for the runner group.
  # The owner reads them (launchd-stderr.log, `_diag`) to see why a runner is
  # offline; the runner user still cannot read the owner's files.
  users.groups.${user}.members = [ local.user ];

  # After nix-darwin creates the runner user and before launchd loads the
  # runners, the same point at which the module creates their directories.
  #
  # The module configures a runner only when its `.runner` is missing, and the
  # listener then uses the work folder recorded there, not the declared one.
  # So a runner whose recorded folder differs (it once pointed at the data
  # volume, which the runner cannot use; see `user`) loses its registration
  # here and registers again under the same name (`replace`).
  system.activationScripts.launchd.text = lib.mkBefore ''
    ${lib.concatMapStrings (name: ''
      state=/var/lib/github-runners/${name}
      if [[ -f "$state/.runner" ]] \
        && ! ${pkgs.gnugrep}/bin/grep -qF ${escapeShellArg ''"workFolder": "${defaultWorkDir name}"''} "$state/.runner"; then
        echo >&2 "GitHub runner ${name}: work folder changed; registering again"
        ${coreutils}/rm -f "$state/.runner" "$state/.credentials" "$state/.credentials_rsaparams"
      fi
    '') names}
    ${coreutils}/mkdir -p /var/lib/github-runners
    if [[ ! -f ${tokenFile} ]]; then
      ${coreutils}/install -m 0640 -o ${escapeShellArg local.user} -g ${user} /dev/null ${tokenFile}
    elif [[ "$(${coreutils}/stat -c '%U:%G:%a' ${tokenFile})" != ${escapeShellArg "${local.user}:${user}:640"} ]]; then
      ${coreutils}/chown ${escapeShellArg local.user}:${user} ${tokenFile}
      ${coreutils}/chmod 0640 ${tokenFile}
    fi
  '';
}
