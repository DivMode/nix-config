{
  lib,
  local,
  pkgs,
  ...
}:
let
  orb = "/opt/homebrew/bin/orb";
  memoryMiB = lib.mapAttrs (
    name: vm:
    let
      memory = vm.memory or "24GiB";
      parts = if builtins.isString memory then builtins.match "([1-9][0-9]*)(GiB|MiB)" memory else null;
    in
    if parts == null then
      throw "ciRunnerVms.${name}.memory must be a positive whole GiB or MiB value for OrbStack"
    else
      lib.toInt (builtins.elemAt parts 0) * (if builtins.elemAt parts 1 == "GiB" then 1024 else 1)
  ) (lib.filterAttrs (_: vm: (vm.engine or "lima") == "orbstack") (local.ciRunnerVms or { }));

  settings = {
    # Make OrbStack the default engine for host Docker commands.
    "docker.set_context" = "true";
    # Run the GUI at login because OrbStack's updater is unavailable headless.
    "app.start_at_login" = "true";
    # Keep CI machines' ports off the LAN.
    "machines.expose_ports_to_lan" = "false";
    # Keep automatic forwarding of CI machine ports off the host.
    "machines.forward_ports" = "false";
    # Fit all declared machines with a 16 GiB floor.
    # At global 16384 MiB, 24576 and 4096 MiB probes both saw MemTotal 16420492 kB.
    # Their memory.max values were 17179869184 and 4294967296 bytes, respectively.
    memory_mib = toString (
      lib.max 16384 (lib.foldl' (acc: mib: acc + mib) 0 (lib.attrValues memoryMiB))
    );
  };
in
{
  _module.args.orbstack = { inherit orb memoryMiB; };

  # OrbStack applies the global memory limit when its VM starts: on the first
  # activation (2026-11-27, OrbStack 2.2.5) `orb config set` printed
  # `Restart OrbStack with "orb stop" to apply changes.`. Report a pending
  # restart instead of interrupting running CI jobs.
  home.activation.configureOrbStack = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin (
    lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "writeBoundary" ] ''
      if [[ -x ${orb} ]]; then
        orbstack_current=$(${orb} config show)
        for orbstack_setting in ${
          lib.escapeShellArgs (lib.mapAttrsToList (key: value: "${key}=${value}") settings)
        }; do
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
