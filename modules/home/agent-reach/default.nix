# Agent-Reach (github.com/Panniantong/Agent-Reach): lets agents read X,
# Reddit, YouTube, GitHub, RSS, web pages and Exa web search through one
# skill. Upstream is a router over other tools, installed by
# `agent-reach install --system` with pip, pipx and npm into the home
# directory. Here each tool it routes to is declared instead, and its skill is
# shipped with a local section that forbids that installer.
#
# Covered: web (Jina Reader via curl), YouTube (yt-dlp + deno), RSS, GitHub
# (gh), Exa search (mcporter), X (twitter-cli), Reddit (rdt-cli). Not covered:
# OpenCLI (a Chrome extension plus daemon; Facebook, Instagram, XiaoHongShu),
# LinkedIn's MCP server, and the Chinese-platform backends.
#
# X and Reddit read the cookies of one Chrome profile, `agentReach.chromeProfile`
# in local.nix (the profile directory name is machine identity). Reading them
# needs one keychain approval for "Chrome Safe Storage".
{
  local,
  pkgs,
  ...
}:
let
  chromeProfile = local.agentReach.chromeProfile or null;

  # Exa's hosted MCP server, exactly what `mcporter config add exa
  # https://mcp.exa.ai/mcp` writes; it needs no API key. Handed to mcporter
  # and to `agent-reach doctor` as MCPORTER_CONFIG, a regular store file:
  # mcporter 0.11 does not read ~/.mcporter, and doctor refuses to read a
  # config through a symlink, which is what a Home Manager file would be.
  mcporterConfig = pkgs.writeText "mcporter.json" (
    builtins.toJSON { mcpServers.exa.baseUrl = "https://mcp.exa.ai/mcp"; }
  );
  mcporter = pkgs.symlinkJoin {
    name = "mcporter-${pkgs.mcporter.version}";
    paths = [ pkgs.mcporter ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/mcporter --set-default MCPORTER_CONFIG ${mcporterConfig}
    '';
  };

  agentReach = pkgs.callPackage ./package.nix { inherit mcporterConfig; };
  twitterCli = pkgs.callPackage ./twitter-cli.nix { inherit chromeProfile; };
  rdtCli = pkgs.callPackage ./rdt-cli.nix { inherit chromeProfile; };

  # The interpreter that has feedparser, for the skill's RSS recipe; bare
  # `python3` is the uv-managed launcher with no packages.
  agentReachPython = pkgs.writeShellScriptBin "agent-reach-python" ''
    exec ${pkgs.python3.withPackages (ps: [ ps.feedparser ])}/bin/python3 "$@"
  '';

  # Upstream's skill in English, references included, with the local section
  # appended. The Chinese SKILL.md is dropped so only one skill file exists.
  skill = pkgs.runCommand "agent-reach-skill" { } ''
    cp -r ${agentReach.src}/agent_reach/skill $out
    chmod -R u+w $out
    mv $out/SKILL_en.md $out/SKILL.md
    cat ${./skill-local.md} >> $out/SKILL.md
  '';
in
{
  home.packages = [
    agentReach
    agentReachPython
    rdtCli
    twitterCli
    mcporter
    pkgs.deno
  ];

  programs.claude-code.skills.agent-reach = skill;
  home.file.".codex/skills/agent-reach" = {
    source = skill;
    recursive = true;
  };
}
