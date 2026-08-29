# OpenAI's Secure MCP Tunnel client.
#
# The ChatGPT path is outbound-only: `tunnel-client` dials OpenAI's control
# plane and drains commands from it, so nothing on this Mac listens on a public
# port and no Tailscale Funnel is involved. See ../../../../ai/tandem/README.md.
#
# Upstream publishes signed release ZIPs rather than source, so this unpacks a
# prebuilt Mach-O binary. The hashes below are the exact digests GitHub reports
# for the release assets, which are also what upstream's own SHA256SUMS.txt
# records — a `fetchurl` pin, not a `fetchzip` NAR hash, precisely so the value
# here can be compared against the published one by eye.
#
# `cloudflared` ships in the same archive and must stay beside the client:
# `tunnel-client run --cloudflared.path` defaults to "the executable beside
# tunnel-client", so separating the pair would silently disable the managed
# Cloudflare Tunnel runtime.
#
# Both therefore live in libexec, with only a wrapper on PATH. ../../development.nix
# already declares nixpkgs' `cloudflared` for the deploy path
# (`cloudflared access tcp`), and AGENTS.md allows exactly one thing to provide
# an executable — installing this bundled copy into bin/ collides with it and
# fails the Home Manager path build outright. The wrapper execs the absolute
# libexec path, so upstream's "beside me" lookup still finds the version
# tunnel-client was released and tested with.
{
  lib,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
  unzip,
}:
let
  version = "0.0.13";

  # Upstream's asset naming, which is Go's GOOS-GOARCH rather than Nix's.
  platforms = {
    aarch64-darwin = {
      asset = "darwin-arm64";
      hash = "sha256-FavxZfBgUK9kLJSLpr1skFGR3FQgqUItrd4rSdiS4sY=";
    };
    x86_64-darwin = {
      asset = "darwin-amd64";
      hash = "sha256-xoPhXYT7mX9a8cx8TLVQCOGaVVqe0uwPiaX/Qm2F+Fw=";
    };
  };

  platform =
    platforms.${stdenvNoCC.hostPlatform.system}
      or (throw "tunnel-client publishes no release asset for ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "tunnel-client";
  inherit version;

  src = fetchurl {
    url = "https://github.com/openai/tunnel-client/releases/download/v${finalAttrs.version}/tunnel-client-v${finalAttrs.version}-${platform.asset}.zip";
    inherit (platform) hash;
  };

  nativeBuildInputs = [
    makeWrapper
    unzip
  ];

  # The archive is a flat directory, so unpacking needs a destination of its own.
  unpackPhase = ''
    runHook preUnpack
    mkdir -p source
    unzip -q "$src" -d source
    runHook postUnpack
  '';

  sourceRoot = "source";

  installPhase = ''
    runHook preInstall

    install -Dm755 tunnel-client "$out/libexec/tunnel-client/tunnel-client"
    install -Dm755 cloudflared "$out/libexec/tunnel-client/cloudflared"
    makeWrapper "$out/libexec/tunnel-client/tunnel-client" "$out/bin/tunnel-client"

    # Upstream's own provenance documents, kept beside the binaries rather than
    # discarded: they are how a reader checks what went into a vendor build
    # that this repository cannot rebuild from source.
    install -Dm644 LICENSE "$out/share/doc/tunnel-client/LICENSE"
    install -Dm644 NOTICE "$out/share/doc/tunnel-client/NOTICE"
    install -Dm644 cloudflared-manifest.json "$out/share/doc/tunnel-client/cloudflared-manifest.json"
    install -Dm644 tunnel-client-v${finalAttrs.version}-${platform.asset}-licenses.txt \
      "$out/share/doc/tunnel-client/licenses.txt"
    install -Dm644 tunnel-client-v${finalAttrs.version}-${platform.asset}.spdx.json \
      "$out/share/doc/tunnel-client/sbom.spdx.json"

    runHook postInstall
  '';

  # A prebuilt vendor binary. Stripping or rewriting it would break the code
  # signature macOS checks before it will run at all.
  dontStrip = true;
  dontPatchELF = true;

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    "$out/bin/tunnel-client" --version | grep -q '^${finalAttrs.version}+'
    runHook postInstallCheck
  '';

  meta = {
    description = "OpenAI Secure MCP Tunnel client";
    homepage = "https://developers.openai.com/api/docs/guides/secure-mcp-tunnels";
    downloadPage = "https://github.com/openai/tunnel-client/releases";
    # Apache-2.0, per the NOTICE in the archive ("Copyright 2026 OpenAI") and
    # the repository's own license metadata. This packages the published
    # binary rather than building from that source, which is what
    # sourceProvenance records below.
    license = lib.licenses.asl20;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = lib.attrNames platforms;
    mainProgram = "tunnel-client";
  };
})
