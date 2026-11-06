{
  inputs,
  pkgs,
  ...
}:
let
  # The same store path modules/darwin/membrake.nix installs, so this alias
  # never resolves a different `membrake` from PATH.
  membrake = inputs.membrake.packages.${pkgs.stdenv.hostPlatform.system}.default;
in
{
  # `cpu-lock` is the command name the agent instructions and the managed
  # command guard already know; the queue itself is `membrake exec`. The old
  # lock-file implementation is gone: --shared, --exclusive and --wait are
  # accepted so existing invocations keep working, and ignored.
  home.packages = [
    (pkgs.writeShellApplication {
      name = "cpu-lock";
      text = ''
        usage() {
          echo "usage: cpu-lock run [--shared|--exclusive] [--wait N] --label LABEL [--] COMMAND [ARG...]" >&2
          echo "       cpu-lock status" >&2
          exit 2
        }

        [ "$#" -ge 1 ] || usage
        action=$1
        shift

        case "$action" in
          status)
            [ "$#" -eq 0 ] || usage
            exec ${membrake}/bin/membrake status
            ;;
          run) ;;
          *) usage ;;
        esac

        label=
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --shared | --exclusive) shift ;;
            --wait)
              [ "$#" -ge 2 ] || usage
              shift 2
              ;;
            --wait=*) shift ;;
            --label)
              [ "$#" -ge 2 ] || usage
              label=$2
              shift 2
              ;;
            --label=*)
              label=''${1#--label=}
              shift
              ;;
            --)
              shift
              break
              ;;
            -*) usage ;;
            *) break ;;
          esac
        done

        [ -n "$label" ] && [ "$#" -ge 1 ] || usage
        exec ${membrake}/bin/membrake exec --label "$label" -- "$@"
      '';
    })
  ];
}
