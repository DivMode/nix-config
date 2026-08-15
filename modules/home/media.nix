# Media file handlers.
#
# IINA is the video player; modules/darwin/homebrew.nix installs the cask,
# because it is a signed vendor application with no nixpkgs Darwin build. This
# module only decides what opens when a video file is double-clicked.
#
# macOS has no "default video player" setting. The mechanism is the
# LaunchServices document-type handler, one binding per UTI, and `duti` is the
# supported CLI for writing it — the same arrangement ./terminal.nix uses to
# claim shell scripts for Ghostty.
{ lib, pkgs, ... }:
let
  # Bound by UTI, not by extension: `duti -s` takes a UTI or a URL scheme, and
  # its `-x` flag is a query rather than a setter.
  #
  # Every identifier below is what this machine actually resolves the extension
  # to, read out of UniformTypeIdentifiers rather than assumed:
  #
  #   swift -e 'import UniformTypeIdentifiers
  #             print(UTType(filenameExtension: "mkv")!.identifier)'
  #
  # That distinction matters. IINA's Info.plist declares most of its types by
  # CFBundleTypeExtensions with 38 UTImportedTypeDeclarations behind them, so
  # the resolved identifier is sometimes Apple's (mp4 is public.mpeg-4), and
  # sometimes IINA's own for a container macOS does not know (mkv is
  # io.iina.mkv). Guessing one family for all of them would silently bind
  # identifiers nothing resolves to.
  videoTypes = [
    # Apple- and vendor-defined types, which win resolution where they exist.
    "com.adobe.flash.video" # flv, f4v, f4p
    "com.apple.m4v-video" # m4v
    "com.apple.quicktime-movie" # mov, qt
    "com.microsoft.advanced-systems-format" # asf
    "com.microsoft.windows-media-wmv" # wmv
    "com.real.realmedia" # rm
    "com.real.realmedia-vbr" # rmvb
    "org.smpte.mxf" # mxf
    "org.webmproject.webm" # webm
    "org.xiph.ogv" # ogm, ogv
    "public.3gpp" # 3gp
    "public.3gpp2" # 3g2
    "public.avchd-mpeg-2-transport-stream" # mts, m2ts
    "public.avi" # avi
    "public.dv-movie" # dv
    "public.mpeg" # mpg, mpeg
    "public.mpeg-2-transport-stream" # ts
    "public.mpeg-2-video" # m2v
    "public.mpeg-4" # mp4

    # Containers macOS defines no type for, where IINA's imported declaration
    # is what the extension resolves to. Redundant while IINA is the only
    # application claiming them, and explicit so that stops being load-bearing.
    "io.iina.divx" # divx
    "io.iina.mkv" # mkv
    "io.iina.mpeg-stream" # m2p
    "io.iina.mpeg-video" # m1v, mpv
    "io.iina.vob" # vob
    "io.iina.wtv" # wtv
  ];
in
{
  # `viewer` mirrors IINA's own CFBundleTypeRole. LaunchServices ignores a role
  # an application does not declare, which is why this is not simply `all`.
  #
  # Deliberately not claimed:
  #
  #   * Audio — IINA plays mp3, m4a, flac and the rest, but claiming them would
  #     take every music file away from Music.app. That is a separate decision
  #     from "what opens a video", so it is not made here.
  #   * public.folder and gif — IINA declares both. A folder would stop opening
  #     in Finder and a GIF would stop opening in Preview.
  #   * mk3d, mks, amv, xvid, yuv — these resolve to dynamic `dyn.ah62…`
  #     identifiers, which macOS synthesises from the extension and are not
  #     stable across systems. Binding one would write a handler entry that
  #     means nothing on the next machine.
  #
  # Unconditional, matching ./terminal.nix: `duti -s` is idempotent, writes
  # only the handler database, and restarts nothing, so the "gate activation on
  # a real change" rule in AGENTS.md has nothing to protect here.
  home.activation.setDefaultVideoHandler = lib.hm.dag.entryAfter [ "writeBoundary" ] (
    lib.concatMapStringsSep "\n" (
      uti: "run ${pkgs.duti}/bin/duti -s com.colliderli.iina ${uti} viewer"
    ) videoTypes
  );
}
