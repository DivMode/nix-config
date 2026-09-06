# Retirement of configuration the old module copied outside Home Manager's
# file links. Keep this migration for hosts upgrading from an older generation.
# No package, service, tunnel, or session is created here.
{ config, lib, ... }:
{
  home.activation.retireTandem =
    lib.hm.dag.entryBetween [ "linkGeneration" "setupLaunchAgents" ] [ "writeBoundary" ]
      ''
        retiredConfig=${lib.escapeShellArg "${config.xdg.configHome}/tandem/config.json"}
          retiredDeclared=${lib.escapeShellArg "${config.home.homeDirectory}/.config/nix-config/ai/tandem-config.json"}
          retiredTarget="gui/$(id -u)/org.nix-community.home.tandem-tunnel"

          # Check ownership before removing a real file. The old declaration is
          # still linked at this point in activation; differing bytes are user
          # state and must not be silently discarded.
          if [[ -e "$retiredConfig" || -L "$retiredConfig" ]]; then
          if [[ -L "$retiredConfig" || ! -f "$retiredConfig" ]] \
            || [[ ! -L "$retiredDeclared" ]] \
              || [[ "$(/usr/bin/readlink "$retiredDeclared")" != /nix/store/* ]] \
              || ! /usr/bin/cmp -s "$retiredDeclared" "$retiredConfig"; then
              echo "Cannot retire Tandem: its runtime configuration differs from the managed declaration." >&2
              exit 1
            fi
          fi

          # Home Manager has previously left this loaded job on an old generation.
          # Verify the exact label and Nix-owned program, then stop only this job.
          if retiredJob=$(/bin/launchctl print "$retiredTarget" 2>/dev/null); then
            if ! printf '%s\n' "$retiredJob" \
              | /usr/bin/grep -qE '/nix/store/[a-z0-9]{32}-tandem-tunnel-service/bin/tandem-tunnel-service'; then
              echo "Cannot retire Tandem: its launchd label runs an unrecognized program." >&2
              exit 1
            fi
            run /bin/launchctl bootout "$retiredTarget"
            if [[ -z "''${DRY_RUN_CMD:-}" ]]; then
              for retiredAttempt in 1 2 3 4 5 6 7 8 9 10; do
                /bin/launchctl print "$retiredTarget" >/dev/null 2>&1 || break
                /bin/sleep 0.2
              done
              if /bin/launchctl print "$retiredTarget" >/dev/null 2>&1; then
                echo "Tandem's launchd job is still loaded after retirement." >&2
                exit 1
              fi
            fi
          fi

          if [[ -e "$retiredConfig" || -L "$retiredConfig" ]]; then
            run rm -f "$retiredConfig"
          fi
          # Home Manager removes its old file links and plist. Credentials, logs,
          # tunnel state and Herdr sessions belong to applications and stay intact.
      '';
}
