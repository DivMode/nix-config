# Agent-Reach's own CLI: `agent-reach doctor` reports which backend serves
# each platform. Built from the pinned GitHub commit; the PyPI package named
# `agent-reach` is a different project (upstream README).
{
  fetchFromGitHub,
  python3Packages,
  mcporterConfig,
}:
python3Packages.buildPythonApplication {
  pname = "agent-reach";
  version = "1.5.0-unstable-2026-09-16";
  pyproject = true;
  src = fetchFromGitHub {
    owner = "Panniantong";
    repo = "Agent-Reach";
    rev = "a19a171fa980a0785849596492e0af4db800c82f";
    hash = "sha256-DVGnyj7kZVKT68BERuuX4oGiMqxqstj2u6J3XpuZ1Gw=";
  };
  build-system = [ python3Packages.hatchling ];
  # `browser-cookie3` is upstream's `cookies` extra. `feedparser` also serves
  # the skill's RSS recipe through `agent-reach-python` (./default.nix).
  dependencies = with python3Packages; [
    browser-cookie3
    feedparser
    loguru
    python-dotenv
    pyyaml
    requests
    rich
    yt-dlp
  ];
  makeWrapperArgs = [
    "--set-default"
    "MCPORTER_CONFIG"
    "${mcporterConfig}"
  ];
  pythonImportsCheck = [ "agent_reach" ];
  meta.mainProgram = "agent-reach";
}
