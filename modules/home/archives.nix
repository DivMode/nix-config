# Archive file handlers.
#
# Keka is the extractor; modules/darwin/homebrew.nix installs the cask. This
# module only decides what opens when an archive is double-clicked, which is a
# separate question that installing the application does not answer.
#
# It does not answer it because LaunchServices never displaces an incumbent
# handler. Registering an application adds it to the candidate list; the
# existing default keeps the binding. Measured on this Mac with Keka 1.6.7
# already installed:
#
#   zip, 7z, tar, gz, tgz, bz2, xz, cpio, cpgz, aar, aea, z   Archive Utility
#   rar                                                       calibre
#   xar, apk, exe, wim, appx, ace, zst, br, lz4, zipx, sqsh    Keka
#
# The pattern is exact and worth stating: Keka won every type nothing else had
# claimed, and lost every type Apple's Archive Utility claims — which is the
# common half. `.rar` went to Calibre, which claims it for comic books. So the
# formats that actually made Keka worth installing were the ones still opening
# in something else.
#
# The mechanism is the same one ./media.nix uses for IINA and ./terminal.nix
# uses for Ghostty: one LaunchServices document-type binding per UTI, written
# with `duti`.
{ lib, pkgs, ... }:
let
  # Bound by the UTI the extension ACTUALLY RESOLVES TO on this machine, read
  # out of UniformTypeIdentifiers rather than copied from Keka's Info.plist:
  #
  #   swift -e 'import UniformTypeIdentifiers
  #             print(UTType(filenameExtension: "cab")!.identifier)'
  #
  # Those two sources disagree more often than they look like they would. Keka
  # declares `com.microsoft.cab-archive`, `com.apple.iTunes.ipa` and
  # `com.sun.java-archive` for .war, while macOS resolves those extensions to
  # `com.microsoft.cab`, `com.apple.itunes.ipa` and
  # `com.sun.web-application-archive`. Binding what the application declares
  # would write handler entries no double-click ever consults.
  archiveTypes = [
    # The types Archive Utility held, which is the whole point of the module.
    "com.apple.archive" # aar, yaa
    "com.apple.bom-compressed-cpio" # cpgz
    "com.apple.encrypted-archive" # aea
    "org.7-zip.7-zip-archive" # 7z
    "org.gnu.gnu-zip-archive" # gz, gzip
    "org.gnu.gnu-zip-tar-archive" # tgz
    "org.tukaani.lzma-archive" # lzma
    "org.tukaani.tar-xz-archive" # txz
    "org.tukaani.xz-archive" # xz
    "public.bzip2-archive" # bz2, bz
    "public.cpio-archive" # cpio, and pax, which resolves to the same type
    "public.tar-archive" # tar
    "public.tar-bzip2-archive" # tbz, tbz2
    "public.z-archive" # z
    "public.zip-archive" # zip

    # Held by Calibre, which claims it for comic books.
    "com.rarlab.rar-archive" # rar, and r00-r99 multi-part volumes

    # Already Keka's, because nothing else claimed them. Declared anyway, so
    # that stays true by decision rather than by nobody else having turned up.
    "com.apple.xar-archive" # xar
    "com.facebook.zstandard-archive" # zst
    "com.facebook.zstandard-tar-archive" # tzst
    "com.google.brotli-archive" # br
    "com.google.brotli-tar-archive" # tbr
    "com.google.snappy-archive" # sz, snappy, snz
    "com.microsoft.appx-archive" # appx, appxbundle
    "com.microsoft.wim-archive" # wim
    "com.microsoft.windows-executable" # exe, for unpacking rather than running
    "com.plougher.squashfs-archive" # sqsh, sqfs, sfs, squashfs
    "com.servmask.wpress-backup" # wpress
    "com.winace.ace-archive" # ace
    "com.winzip.zipx-archive" # zipx
    "net.webrecorder.wacz-archive" # wacz
    "public.archive.apk" # apk, xapk
    "public.archive.lha" # lha, lzh
    "public.lrzip-archive" # lrz
    "public.lrzip-tar-archive" # tlrz
    "public.lz4-archive" # lz4
    "public.lz4-tar-archive" # tlz4
    "public.lzip-archive" # lz
    "public.lzip-tar-archive" # tlz
    "public.lzop-tar-archive" # tzo
  ];
in
{
  # `viewer` mirrors Keka's own CFBundleTypeRole, which is Viewer for all 67 of
  # its document types. LaunchServices ignores a role an application does not
  # declare, which is why this is not simply `all`.
  #
  # Deliberately NOT claimed, though Keka declares every one of them:
  #
  #   * dmg and iso (com.apple.disk-image-udif, public.iso-image) — these open
  #     in DiskImageMounter, and mounting is what double-clicking a disk image
  #     should do. Extracting one to a folder is occasionally useful and never
  #     the default anyone wants.
  #   * xip (com.apple.xip-archive) — Archive Utility verifies the Apple code
  #     signature on a .xip before expanding it, which is the entire reason the
  #     format exists. Keka would unpack it without that check.
  #   * jar (com.sun.java-archive) — JavaLauncher runs it. A .jar is a zip, but
  #     claiming it would turn "run this program" into "extract this program".
  #   * ipa (com.apple.itunes.ipa) — com.apple.IPAInstaller holds it.
  #   * epub, mobi, azw, ibooks — e-books belong to Books and Calibre. They are
  #     zip containers underneath, which is why Keka declares them, and that is
  #     not a reason to open one in an extractor.
  #   * safariextz (com.apple.safari.extension) — Safari's.
  #   * public.data — Keka declares the catch-all, and its `*` extension entry
  #     alongside it. Binding it would make Keka the default for every file
  #     type macOS cannot otherwise identify.
  #   * cbr, cbz, lzo, msi, spk, cpt, xpi, iwa, mdz and the 001-099 volume
  #     extensions — these resolve to dynamic `dyn.ah62…` identifiers, which
  #     macOS synthesises from the extension and which are not stable across
  #     systems. Binding one writes an entry that means nothing on the next
  #     machine. Same exclusion, for the same reason, as ./media.nix.
  #   * war (com.sun.web-application-archive) — Archive Utility holds it, and
  #     Keka declares .war under a different identifier than macOS resolves it
  #     to, so the claim would be ignored rather than applied.
  #
  # Unconditional, matching ./media.nix and ./terminal.nix: `duti -s` is
  # idempotent, writes only the handler database, and restarts nothing.
  home.activation.setDefaultArchiveHandlers = lib.hm.dag.entryAfter [ "writeBoundary" ] (
    lib.concatMapStringsSep "\n" (
      uti: "run ${pkgs.duti}/bin/duti -s com.aone.keka ${uti} viewer"
    ) archiveTypes
  );
}
