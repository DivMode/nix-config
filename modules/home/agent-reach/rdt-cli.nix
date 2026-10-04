# rdt-cli: Agent-Reach's Reddit backend. Reddit has no logged-out path left
# (anonymous .json is blocked, the API closed self-service keys in 2025-11),
# so it reads with a signed-in session's cookies.
#
# Pinned to the commit Agent-Reach itself pins (agent_reach/channels/reddit.py,
# `_RDT_GIT_SOURCE`): PyPI still only has 0.4.1.
#
# Upstream extraction takes the first browser with Reddit cookies through
# browser_cookie3's default, which is Chrome's Default profile, and prefers a
# `uv run --with browser-cookie3` subprocess that downloads outside Nix. The
# patch adds RDT_CHROME_PROFILE: when set, only that Chrome profile is read.
{
  lib,
  fetchFromGitHub,
  python3Packages,
  chromeProfile ? null,
}:
python3Packages.buildPythonApplication {
  pname = "rdt-cli";
  version = "0.4.2-unstable-2026-03-21";
  pyproject = true;
  src = fetchFromGitHub {
    owner = "public-clis";
    repo = "rdt-cli";
    rev = "5e4fb3720d5c174e976cd425ccc3b879d52cac66";
    hash = "sha256-LcilFSeMEqS5v2soDqAPPN5wCl4/U50jzdspOlq0s+I=";
  };
  patches = [ ./rdt-cli-chrome-profile.patch ];
  build-system = [ python3Packages.hatchling ];
  dependencies = with python3Packages; [
    browser-cookie3
    click
    httpx
    pyyaml
    rich
  ];
  makeWrapperArgs = lib.optionals (chromeProfile != null) [
    "--set-default"
    "RDT_CHROME_PROFILE"
    (lib.escapeShellArg chromeProfile)
  ];
  pythonImportsCheck = [ "rdt_cli" ];
  meta.mainProgram = "rdt";
}
