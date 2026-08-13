{ ... }:
{
  # macOS ships the application firewall OFF, and it was off on this host until
  # 2026-08-13. `system.defaults.alf.*` is removed in current nix-darwin; these
  # are the replacement options.
  networking.applicationFirewall = {
    enable = true;

    # Do not answer probes for closed ports. Costs nothing on a workstation and
    # removes it from trivial network scans.
    enableStealthMode = true;

    # Deliberately NOT enabled. "Block all incoming connections" also blocks
    # AirDrop, screen sharing, printer discovery, and every locally bound
    # development server, which is unusable on a machine used for development.
    # The default posture — allow signed software, prompt for the rest — is the
    # right trade here.
    blockAllIncoming = false;

    # Apple-signed and validly signed third-party software may accept incoming
    # connections without prompting. Turning these off produces a stream of
    # dialogs after every application update and trains you to click Allow.
    allowSigned = true;
    allowSignedApp = true;
  };
}
