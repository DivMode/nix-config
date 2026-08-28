{
  lib,
  local,
  ...
}:
{
  # One owner for the download directory's EXISTENCE. dock.nix and chrome.nix
  # only name it.
  #
  # It has to exist before either of them is useful, and both fail quietly when
  # it does not: a Dock stack pinned to a missing path renders as a question
  # mark and never re-checks, and Chrome cannot create a directory under
  # /Volumes itself, that being root:wheel drwxr-xr-x.

  # Validate collisions before Home Manager begins writing any managed state,
  # matching the screenshots directory in ./default.nix.
  home.activation.validateDownloadsDirectory = lib.hm.dag.entryBefore [ "writeBoundary" ] ''
    downloadsDirectory=${lib.escapeShellArg local.downloadsDirectory}

    if [[ -L "$downloadsDirectory" || ( -e "$downloadsDirectory" && ! -d "$downloadsDirectory" ) ]]; then
      echo "Cannot create $downloadsDirectory because a symlink or non-directory already exists" >&2
      exit 1
    fi

    # The parent is checked separately so an unmounted external volume reports
    # itself. Without this the failure arrives as a bare "Permission denied"
    # from mkdir — /Volumes is root-owned, so a user agent cannot create a
    # mountpoint there — which reads as a permissions bug rather than as a disk
    # that is not plugged in.
    downloadsParent=$(dirname "$downloadsDirectory")
    if [[ ! -d "$downloadsParent" ]]; then
      echo "Cannot create $downloadsDirectory because $downloadsParent does not exist; is that volume mounted?" >&2
      exit 1
    fi
  '';

  # `run` preserves Home Manager's dry-run behavior.
  home.activation.ensureDownloadsDirectory = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run mkdir -p ${lib.escapeShellArg local.downloadsDirectory}
  '';
}
