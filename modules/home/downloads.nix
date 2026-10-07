{
  lib,
  local,
  pkgs,
  ...
}:
let
  volumeMatch = builtins.match "/Volumes/([^/]+)(/.*)?" local.downloadsDirectory;
  volumeRoot = if volumeMatch == null then "" else "/Volumes/${builtins.head volumeMatch}";

  # Both phases check again: a volume can disappear between validation and
  # writing. /Volumes/<name> belongs to the volume mounter, not Home Manager.
  # network-shares.nix deliberately defers mounting during install-only setup
  # until setup-mac.sh seeds the Keychain; creating a local mountpoint here
  # would either fail as the user or occupy the path before NetFS mounts it.
  checkDownloadsDirectory = ''
    downloadsDirectory=${lib.escapeShellArg local.downloadsDirectory}
    downloadsVolume=${lib.escapeShellArg volumeRoot}
    downloadsReady=1

    for path in "$downloadsDirectory" "$downloadsVolume"; do
      if [[ -n "$path" && ( -L "$path" || ( -e "$path" && ! -d "$path" ) ) ]]; then
        echo "Cannot use $path for downloads because a symlink or non-directory already exists" >&2
        exit 1
      fi
    done

    if [[ -n "$downloadsVolume" ]]; then
      # Directory existence is not proof of a mount: a stale empty directory
      # must not become an accidental download destination on the system disk.
      downloadsMounted=$(${pkgs.python3}/bin/python3 -c \
        'import os, sys; print("yes" if os.path.ismount(sys.argv[1]) else "no")' \
        "$downloadsVolume")
      if [[ "$downloadsMounted" == no ]]; then
        downloadsReady=0
      fi
    fi

    if [[ "$downloadsReady" == 1 ]]; then
      if [[ -d "$downloadsDirectory" ]]; then
        if [[ ! -w "$downloadsDirectory" || ! -x "$downloadsDirectory" ]]; then
          echo "Downloads directory $downloadsDirectory is not writable/searchable by the current user" >&2
          exit 1
        fi
      else
        downloadsParent=$(dirname "$downloadsDirectory")
        if [[ ! -d "$downloadsParent" || ! -w "$downloadsParent" || ! -x "$downloadsParent" ]]; then
          echo "Cannot create $downloadsDirectory: parent $downloadsParent is missing or not writable/searchable" >&2
          exit 1
        fi
      fi
    fi
  '';
in
{
  # Only local directories (or subdirectories of a mounted volume) are ours to
  # create. Missing volumes are a normal offline/bootstrap state, not a reason
  # to block installation. Chrome and the Dock keep the declared path; no
  # alternate destination or symlink is introduced while storage is offline.
  home.activation.validateDownloadsDirectory = lib.hm.dag.entryBefore [
    "writeBoundary"
  ] checkDownloadsDirectory;

  home.activation.ensureDownloadsDirectory = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${checkDownloadsDirectory}
    if [[ "$downloadsReady" == 0 ]]; then
      echo "Downloads volume $downloadsVolume is not mounted; leaving $downloadsDirectory unchanged. Downloads require that volume."
    elif [[ ! -d "$downloadsDirectory" ]]; then
      run mkdir -p "$downloadsDirectory"
    fi
  '';
}
