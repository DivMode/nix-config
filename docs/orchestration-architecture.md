# Agent coordination architecture

Coding work runs in the active local client, using that client's native tools
for execution, delegation, status and review. This repository installs no
remote agent-control service. The former Tandem deployment and Secure MCP
Tunnel were retired at the owner's request on 2026-09-06 UTC.

## Instructions and authority

[`ai/instructions/orchestration.md`](../ai/instructions/orchestration.md) is the
policy for coordination. It is composed with the shared working instructions
and delivered identically to Claude Code and Codex by Home Manager. Checks
verify both the composition and the bytes supplied to each client.

The user sets intent. The active coordinator sequences work and reviews the
evidence. Significant implementation and independent review remain separate
when practical; a worker's own report is not an independent approval. GitHub
issues, pull requests and commits hold durable decisions and results.

Local instruction files do not reach a browser conversation automatically.
Supply relevant instructions with a remote task rather than assuming that
participant has read the Mac's configuration.

## Worker ownership

Inspect existing workers before creating another. Reuse the worker that owns
the task, and follow it through the current client's status and wait tools.
An interrupted conversation does not imply that its worker stopped. A past
completion event and current worker liveness are separate observations.

Most work needs one agent. Delegate only independent work with explicit file
ownership, or an independent review. Do not create workers solely to monitor
other workers, and do not manipulate personal terminal sessions.

## Configuration and mutable state

Nix owns installed tools and desired configuration. Clients and Herdr own
authentication, conversations, sessions and caches. The full boundary is in
[`state-boundary.md`](state-boundary.md).

Retirement removes the old package, tunnel binary, launchd service, shell
injection and declared host settings. A small activation migration stops only
the verified former launchd job and removes the copied runtime configuration
only when it matches its managed declaration. Home Manager removes obsolete
links and the service plist. Credentials, logs and session history are retained;
removing a service is not permission to erase application data.

## Verification

Run the repository's checks and activation script. Verify the removed service
is absent from launchd, its commands are absent from the active profile, and
both clients now receive the same instructions without any dependency on the
retired service. Repeating activation must leave it absent.
