# Local CLIProxyAPI and CPA Manager Plus

The Mac profile enables upstream CLIProxyAPI with **CPA Manager Plus Full**.
Both are native Darwin packages supervised by Home Manager launch agents.
Release versions and SHA-256 archive hashes live in
`modules/home/cli-proxy-pin.json`; there are no runtime binary or panel updates.
`nixup cli-proxy` advances both releases through the existing checked rebuild
workflow; a full `nixup` includes them. GitHub release asset digests are pinned,
and Nix verifies downloaded archive bytes against those hashes at build time.
The Manager binary embeds the dashboard. Docker, a public domain, and a reverse
proxy are unnecessary for this local deployment.

## Access

- Dashboard: <http://127.0.0.1:18317/management.html>
- OpenAI-compatible client base URL: <http://127.0.0.1:8317/v1>
- CPA management API: `http://127.0.0.1:8317/v0/management`

Run `cli-proxy-dashboard` to copy the dashboard admin key to the clipboard and
open the dashboard. Paste it into the login field. The gateway connection and
its separate management key are already configured; no registration is needed.
Run `cli-proxy-client-key` to copy the inference client key, then paste that key
into the coding client's API-key field alongside the base URL above.

These are three separate keys: the dashboard admin key, CPA management key, and
inference client key. They are generated privately on first activation and are
never printed by the helper commands. Do not use a management key as a client
key. Clear the clipboard after pasting if desired.

## Add provider accounts

In the dashboard, use **OAuth Login** to start the provider's login and complete
its browser authorization. **Credential Management** shows the resulting account
credentials. API-key providers can instead be configured under **AI Providers**.

From a terminal, the same deployment is available through:

```sh
cli-proxy-login codex
cli-proxy-login codex-device
cli-proxy-login claude
cli-proxy-login antigravity
```

Choose the provider you actually use. Each command runs a login flow; the user
must authorize their own account. No existing coding-client sessions are copied.
The initial empty dashboard is expected until providers are added and real
requests pass through this gateway. Full mode collects the HTTP usage queue
into local SQLite for request history and cost/usage views. Cost values are
estimates derived from model prices, not provider invoices.

## Ownership and private state

Default state directory:
`~/Library/Application Support/nix-config/cli-proxy/`

| Path | Owner and purpose |
| --- | --- |
| `keys/{admin,management,client}` | Private application-generated keys, mode 0600 |
| `gateway/config.yaml` | Writable CPA config; provider entries remain application-owned |
| `auth/` | Provider OAuth credentials; application-owned |
| `manager/usage.sqlite*` | Manager settings and persistent history; application-owned |
| `manager/data.key` | Manager encryption key; required to recover encrypted connections |
| `logs/` and `gateway/logs/` | Private application logs |
| `.nix-managed` | Deployment ownership marker |

Nix owns versions, supervision, listener addresses, key-file paths, disabled
discovery/plugins/profiling, bounded CPA file logging, and usage collection.
Activation reasserts those fields while preserving provider configurations and
additional client keys. Repeating activation leaves keys unchanged and does
not rewrite unchanged configuration or restart unchanged launch agents.
Missing keys/configuration on an initialized deployment fail closed. Restore
the missing state rather than deleting the marker or silently rotating keys.
An existing unmanaged deployment or symlink collision is rejected.

Both listeners bind only to `127.0.0.1`; CPA remote management is disabled and
all management calls require authentication. The standalone CPA panel is
disabled in favor of Manager Full. No LAN announcement, public tunnel, or
firewall exception is configured. OAuth may temporarily start a provider
callback listener while the user signs in.

For home-lab access from another computer, use a deliberate authenticated SSH
tunnel to these loopback ports. Do not enable CPA remote management or publish
the dashboard to the Internet. A future server deployment should have its own
host module and private-network policy.

Back up the whole private state directory, including `data.key` and the three
keys. Stop both services for a consistent SQLite copy; include SQLite companion
files when present. Nix/Git can reconstruct software but cannot reconstruct
OAuth sessions or request history. History is retained until explicitly managed
through the application; there is no automatic data deletion policy here.

## Apply and inspect

From the configuration repository root:

```sh
export NIX_CONFIG_LOCAL="$PWD/local.nix"
nix fmt
nix flake check --impure
nix eval --impure .#darwinConfigurations.example-mac.system
./scripts/rebuild.sh
launchctl print "gui/$(id -u)/org.nix-community.home.cli-proxy-api"
launchctl print "gui/$(id -u)/org.nix-community.home.cpa-manager-plus"
curl -fsS http://127.0.0.1:18317/health
lsof -nP -iTCP:8317 -iTCP:18317 -sTCP:LISTEN
```

`stateDirectory`, `gatewayPort`, and `dashboardPort` are options under
`nixConfig.cliProxy`. Disable the module by disabling it in the Mac profile;
Home Manager removes the launch agents while retaining private application
state. No other clients are automatically redirected through the gateway.

Upstream references: [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)
and [CPA Manager Plus native deployment](https://seakee.github.io/CPA-Manager-Plus/deployment/native.html).
