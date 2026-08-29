# The DivMode Tandem fork, built from the exact commit pinned in ../../../../flake.nix.
#
# Tandem is a TypeScript project with no build step: every entrypoint is run as
# `node --experimental-strip-types <file>.ts`, so this installs the source tree
# beside its production `node_modules` and wraps the stdio entrypoint. Node 24
# strips types natively; the flag is kept because it is what upstream's own
# package.json scripts pass, and dropping it would make the wrapper and the
# documented manual command diverge.
#
# Only `src/`, `bridge/`, and `package.json` are installed. package.json is not
# optional decoration — it carries `"type": "module"`, without which Node
# refuses every import in the tree. `test/`, `setup.sh`, and the upstream
# Tailscale hub assets are deliberately left out: ../default.nix generates the
# protected runtime configuration that `setup.sh desktop` would otherwise
# write, so shipping the installer as well would leave two things able to
# produce that file and no way to tell which one did.
{
  lib,
  buildNpmPackage,
  makeWrapper,
  nodejs_24,
  src,
  # The pinned fork commit, so `tandem-doctor` can report the exact source this
  # binary was built from without a network call.
  rev,
}:
buildNpmPackage (finalAttrs: {
  pname = "tandem";
  version = "0.1.0-herdr.${builtins.substring 0 12 rev}";

  inherit src;

  # Rebuild receipt for the npm dependency closure, not a value to maintain by
  # hand: change the pinned commit and the build fails with the hash to paste
  # here, the same way ../../development.nix documents gcx's vendorHash.
  npmDepsHash = "sha256-iZUI6osOcJFml6or2bXmBTi36ix92dxzhOMhs7FglWE=";

  # There is no `build` script and no `bin` entry, so npm's build and install
  # hooks have nothing to find and would fail looking.
  dontNpmBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/lib/tandem"
    cp -r bridge src package.json "$out/lib/tandem/"
    cp -r node_modules "$out/lib/tandem/node_modules"

    # The stdio MCP server: the only entrypoint these hosts use. The HTTP and
    # device servers are upstream's Tailscale fleet transport, which this
    # configuration deliberately does not run — see ../../../../ai/tandem/README.md.
    makeWrapper ${lib.getExe nodejs_24} "$out/bin/tandem-stdio" \
      --add-flags "--experimental-strip-types" \
      --add-flags "$out/lib/tandem/src/stdio-server.ts"

    runHook postInstall
  '';

  # Prove the wrapper can actually load the patched TypeScript through Node's
  # type stripping. Without a cwd allowlist Tandem warns and still starts, so
  # the check drives it far enough to import the router and then closes stdin,
  # which is how a stdio MCP server is told to exit.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    "$out/bin/tandem-stdio" < /dev/null 2>&1 | grep -q 'cwd allowlist is empty'
    runHook postInstallCheck
  '';

  passthru = {
    inherit rev;
    nodejs = nodejs_24;
  };

  meta = {
    description = "MCP bridge that drives real Claude Code and Codex sessions, with a native Herdr terminal backend";
    homepage = "https://github.com/DivMode/tandem";
    license = lib.licenses.mit;
    platforms = lib.platforms.darwin;
    mainProgram = "tandem-stdio";
  };
})
