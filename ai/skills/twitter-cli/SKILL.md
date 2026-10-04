---
name: twitter-cli
description: "Read X (Twitter) from the shell with the `twitter` CLI: search posts, read a post and its replies, a user's profile and posts, lists, articles. Use when a task needs X content or an x.com/twitter.com link's contents. Read-only unless the user explicitly asks to post, like, follow or otherwise act on X."
---

# twitter-cli

`twitter` is installed by the Nix configuration (`modules/home/twitter-cli.nix`).
Never install, upgrade or replace it with `uv tool`, `pipx` or `pip`; a version
change belongs in that file.

It authenticates with the cookies of the Chrome profile that is signed in to
x.com, read on each run. Always set `TWITTER_BROWSER=chrome`. Check the session
before other commands:

```bash
TWITTER_BROWSER=chrome twitter status --yaml
```

If it reports no session, tell the user to sign in to x.com in Chrome. Do not
ask for or export cookies.

## Reading

Prefer `--json` and a small `-n`. For compact, LLM-friendly output put `-c`
before the subcommand: `twitter -c search ...`.

```bash
TWITTER_BROWSER=chrome twitter search "NVDA calls" -t latest -n 20 --json
TWITTER_BROWSER=chrome twitter search --from unusual_whales --since 2026-10-01 --json
TWITTER_BROWSER=chrome twitter tweet <post-id-or-url> --json   # post and replies
TWITTER_BROWSER=chrome twitter user <handle> --json
TWITTER_BROWSER=chrome twitter user-posts <handle> -n 20 --json
TWITTER_BROWSER=chrome twitter article <post-id-or-url> --markdown
```

`twitter <command> --help` lists every filter.

## Rules

- The session is the user's own X account. Automated use can get it rate
  limited or suspended: keep request counts low, never loop or crawl at volume.
- Write commands (`post`, `reply`, `quote`, `like`, `retweet`, `follow`,
  `bookmark`, `delete` and their reverses) act as the user in public. Run one
  only when the user explicitly asks for that action.
