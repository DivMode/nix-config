{
  lib,
  pkgs,
  ...
}:
let
  orb = "/opt/homebrew/bin/orb";
  settings = {
    # Make OrbStack the default engine for host Docker commands.
    "docker.set_context" = "true";
    # Run the GUI at login because OrbStack's updater is unavailable headless.
    "app.start_at_login" = "true";
    # Keep CI machines' ports off the LAN.
    "machines.expose_ports_to_lan" = "false";
    # Keep automatic forwarding of CI machine ports off the host.
    "machines.forward_ports" = "false";
  };
in
{
  _module.args.orbstack = { inherit orb; };

  # OrbStack applies the global memory limit when its VM starts: on the first
  # activation (2026-11-27, OrbStack 2.2.5) `orb config set` printed
  # `Restart OrbStack with "orb stop" to apply changes.`. Report a pending
  # restart instead of interrupting running CI jobs.
  home.activation.configureOrbStack = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin (
    lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "writeBoundary" ] ''
      if [[ -x ${orb} ]]; then
        # Read the host's capacity at activation. OrbStack releases unused memory.
        orbstack_host_memory=$(/usr/sbin/sysctl -n hw.memsize)
        orbstack_host_cpu=$(/usr/sbin/sysctl -n hw.ncpu)
        orbstack_current=$(${orb} config show)
        for orbstack_setting in ${
          lib.escapeShellArgs (lib.mapAttrsToList (key: value: "${key}=${value}") settings)
        } "memory_mib=$((orbstack_host_memory / 1048576))" "cpu=$orbstack_host_cpu"; do
          orbstack_key="''${orbstack_setting%%=*}"
          orbstack_value="''${orbstack_setting#*=}"
          if /usr/bin/grep -Fxq -- "$orbstack_key: $orbstack_value" <<< "$orbstack_current"; then
            continue
          fi
          run ${orb} config set "$orbstack_key" "$orbstack_value"
          if [[ ! -v DRY_RUN ]]; then
            echo "OrbStack set $orbstack_key to $orbstack_value"
            if [[ "$orbstack_key" == memory_mib ]]; then
              echo "OrbStack restart pending to apply memory_mib=$orbstack_value. Restart after CI jobs finish."
            fi
          fi
        done
      fi
    ''
  );
}
