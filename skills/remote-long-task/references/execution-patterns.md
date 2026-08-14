# Remote execution patterns

## Contents

- Blocking API jobs
- Multi-stage jobs
- Timeouts and retries
- PowerShell and SSH quoting
- Provider deployment

## Blocking API jobs

Do not keep a local client attached to a synchronous generation endpoint for tens of minutes. Start the request remotely in the background, persist the task identifier and logs, and wait for a durable output or state. Before retrying after a disconnect, check the server log and accelerator utilization so an orphaned request is not duplicated.

Prefer a genuinely asynchronous endpoint when it supports server-side cancellation. Verify whether cancellation stops computation or only removes API metadata; do not assume GPU work was released.

## Multi-stage jobs

Split preparation, model loading, generation, and packaging into separate observable stages. Give each stage its own condition and health check. A service port opening is not necessarily model readiness; wait for the documented readiness marker or a real health probe.

Separate progress observation from completion waiting. Make one read-only progress query when useful; do not combine continuous telemetry with a local polling loop.

## Timeouts and retries

Use layered bounded timeouts:

| Layer | Purpose |
|---|---|
| SSH connect timeout | Bound handshake failure |
| Remote task timeout | Authoritative execution limit |
| Remote waiter timeout | Bound state/condition waiting |
| Local tool timeout | Final transport fallback |

Retry SSH handshake failures a small fixed number of times. Do not retry task submission unless durable state proves it was not accepted. Do not use unlimited retries.

## PowerShell and SSH quoting

PowerShell expands `$` in double-quoted strings and can interpret redirection before SSH receives it. If a remote command contains variables, redirection, pipelines, loops, or nested quoting:

1. Create a UTF-8 shell script locally with `apply_patch`.
2. Validate it locally when a compatible shell is available.
3. Upload it with SCP using `BatchMode=yes`.
4. Run a simple command such as `bash /tmp/task-wrapper.sh`.

Keep PowerShell scripts ASCII where Windows PowerShell 5.1 compatibility matters.

## Provider deployment

Do not encode a provider's shared-storage path in the reusable Skill. Pass an explicit work directory. A project may deploy the bundled scripts to its shared `ops/` directory, but that location is project configuration, not a universal default.

For network/FUSE storage, verify whether page-cache prewarming has any effect before spending time and memory on it. Keep generated artifacts, logs, and state together on persistent storage when the compute instance is ephemeral.

