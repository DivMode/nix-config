# Media file handlers.
#
# IINA is the media player for both video and audio;
# modules/darwin/homebrew.nix installs the cask, because it is a signed vendor
# application with no nixpkgs Darwin build. This module only decides what opens
# when a media file is double-clicked.
#
# macOS has no "default media player" setting. The mechanism is the
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

  # Audio, resolved the same way. This takes mp3, m4a, wav and aiff from
  # Music.app, and aac and ac3 from Books, which is the point rather than a
  # side effect: IINA is the media player on this machine.
  audioTypes = [
    "com.apple.coreaudio-format" # caf
    "com.apple.m4a-audio" # m4a
    "com.microsoft.waveform-audio" # wav
    "com.microsoft.windows-media-wma" # wma
    "com.real.realaudio" # ra, ram
    "org.xiph.flac" # flac
    "org.xiph.ogg-audio" # ogg, oga
    "public.aac-audio" # aac
    "public.ac3-audio" # ac3
    "public.aiff-audio" # aiff, aif
    "public.mp2" # mp2
    "public.mp3" # mp3

    # Formats macOS defines no type for.
    "io.iina.ac3" # a52
    "io.iina.ape" # ape
    "io.iina.cue" # cue
    "io.iina.dff" # dff
    "io.iina.dsf" # dsf
    "io.iina.mka" # mka
    "io.iina.mpeg-audio" # m2a, mp1, mpa
    "io.iina.mpeg3-audio" # mpg3
    "io.iina.opus" # opus
    "io.iina.wv" # wv
  ];

  # Playlists. Separate from audio because they are pointers to media rather
  # than media, but claimed for the same reason — they were opening in
  # Music.app, so this is one player handing off to another.
  playlistTypes = [
    "public.m3u-playlist" # m3u, m3u8
    "public.pls-playlist" # pls
  ];
in
{
  # `viewer` mirrors IINA's own CFBundleTypeRole. LaunchServices ignores a role
  # an application does not declare, which is why this is not simply `all`.
  #
  # Deliberately not claimed:
  #
  #   * m4b — it resolves to com.apple.protected-mpeg-4-audio-b, the FairPlay
  #     type, and IINA cannot decrypt it. Claiming it would send purchased
  #     audiobooks to a player that will refuse to open them, so Books keeps
  #     the association. Unprotected .m4b files are rare enough that losing
  #     them to Books is the cheaper mistake of the two.
  #   * public.folder and gif — IINA declares both. A folder would stop opening
  #     in Finder and a GIF would stop opening in Preview.
  #   * mk3d, mks, amv, xvid, yuv, acm, aa3, pcm, tak, tta, vox — these resolve
  #     to dynamic `dyn.ah62…` identifiers, which macOS synthesises from the
  #     extension and are not stable across systems. Binding one would write a
  #     handler entry that means nothing on the next machine.
  #
  # Unconditional, matching ./terminal.nix: `duti -s` is idempotent, writes
  # only the handler database, and restarts nothing, so the "gate activation on
  # a real change" rule in AGENTS.md has nothing to protect here.
  home.activation.setDefaultMediaHandlers = lib.hm.dag.entryAfter [ "writeBoundary" ] (
    lib.concatMapStringsSep "\n" (
      uti: "run ${pkgs.duti}/bin/duti -s com.colliderli.iina ${uti} viewer"
    ) (videoTypes ++ audioTypes ++ playlistTypes)
  );
}
