
## This machine (overrides the rules above)

Every tool here is installed by the Nix configuration (`modules/home/agent-reach`).
Never run `agent-reach install`, `agent-reach uninstall`, `pipx`, `uv tool`,
`pip install`, `npm install -g`, or fetch upstream install/update guides; skip
standing rule 5 (`check-update`). A missing or outdated tool is a change to that
module: report it instead.

- **Browser sessions:** `twitter` and `rdt` read cookies from one Chrome profile
  chosen in the Nix configuration. Do not set `TWITTER_*`, `RDT_*` or cookie
  variables, do not export cookies, and do not try other profiles. Ignore the
  Twitter boundary above that says to supply `TWITTER_AUTH_TOKEN`/`TWITTER_CT0`.
  Check the account first with `twitter whoami --yaml` or `rdt whoami`; if it
  reports no session, ask the user to sign in to that site in that Chrome
  profile.
- **Reddit:** use `rdt` (`rdt search "query" --limit 10`, `rdt read <id>`).
  OpenCLI is not installed.
- **YouTube:** `yt-dlp` with `deno` as its JavaScript runtime. Use the
  scratchpad or `/tmp` for output.
- **RSS:** use `agent-reach-python` in place of `python3` in references/web.md;
  it is the interpreter that has `feedparser`.
- **Exa search:** `mcporter call exa.web_search_exa ...` is configured; no key.
- **Not installed:** OpenCLI (Facebook, Instagram, XiaoHongShu), LinkedIn's MCP
  server, bili-cli, Boss and Xiaoyuzhou backends. Say so rather than installing.
- **Write actions** (post, reply, like, vote, follow, subscribe, comment) act as
  the user in public. Run one only when the user explicitly asks for it. Keep
  request volume low; these are real accounts.
