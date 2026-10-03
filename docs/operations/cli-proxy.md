# Local CLIProxyAPI and CPA Manager Plus

The Mac profile enables upstream CLIProxyAPI with **CPA Manager Plus Full**.
Both are native Darwin packages supervised by Home Manager launch agents.
Release versions, source archive hashes, and dependency hashes live in
`modules/home/cli-proxy-pin.json`; there are no runtime binary or panel updates.
Nix builds the pinned upstream gateway, Manager backend, and dashboard with small
local patches. These remove server authentication and open the dashboard directly.
The builds refuse non-loopback listener addresses, reject foreign HTTP Host and
browser Origin values, and accept local requests without credentials.
`nixup cli-proxy` advances the releases through the existing checked rebuild
workflow; a full `nixup` includes them. Patch or build failures stop the update.
Dependency hashes are refreshed only for source versions advanced by that run.
Changes to the local lock-completion workflow require reviewing and repinning
its output hash through the normal development build.
Docker, a public domain, and a reverse proxy are unnecessary for this deployment.

## Access

- Dashboard: <http://127.0.0.1:18317/management.html>
- OpenAI-compatible client base URL: <http://127.0.0.1:8317/v1>
- CPA management API: `http://127.0.0.1:8317/v0/management`

Run `cli-proxy-dashboard` to open the dashboard. There is no login or local
access key. The inference and WebSocket endpoints also accept requests without an API key.
If a coding client requires a non-empty API-key field, use `local`; it is a
non-secret placeholder, and the server does not validate it.

Manager and panel use that same placeholder internally because upstream
components expect a non-empty connection marker. Requests without any
Authorization header are also accepted. Old access-key files and the old
SQLite admin record are preserved as inactive application state; they are
neither loaded nor checked by this deployment.

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
| `keys/` (older installations only) | Inactive legacy keys; untouched |
| `gateway/config.yaml` | Writable CPA config; provider entries remain application-owned |
| `auth/` | Provider OAuth credentials; application-owned |
| `manager/usage.sqlite*` | Manager settings and persistent history; application-owned |
| `manager/data.key` | Manager encryption key; required to recover encrypted connections |
| `logs/` and `gateway/logs/` | Private application logs |
| `.nix-managed` | Deployment ownership marker |

Nix owns versions, supervision, listener addresses, no-key local access, disabled
discovery/plugins/profiling, bounded CPA file logging, and usage collection.
Activation reasserts those fields while preserving provider configurations and
application history. Activation removes local server/client access keys from
the gateway configuration. Repeating activation does not rewrite unchanged configuration or restart unchanged launch agents.
A scoped activation check compares launchd’s loaded command with each declared
command, correcting stale registrations on macOS versions that reject Home
Manager’s `bootout --wait` command.
Missing configuration on an initialized deployment fails closed. Restore
the missing state rather than deleting the marker.
An existing unmanaged deployment or symlink collision is rejected.

Both listeners bind only to `127.0.0.1`; CPA remote management is disabled and
local management calls require no authentication. The standalone CPA panel is
disabled in favor of Manager Full. No LAN announcement, public tunnel, or
firewall exception is configured. OAuth may temporarily start a provider
callback listener while the user signs in.

For home-lab access from another computer, use a deliberate authenticated SSH
tunnel to these loopback ports. Do not enable CPA remote management or publish
the dashboard to the Internet. A future server deployment should have its own
host module and private-network policy.

Back up the whole private state directory, including `data.key`. Stop both services
for a consistent SQLite copy; include SQLite companion
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
