# Incident-derived lessons

Read this file when a long task behaves unexpectedly. These are mechanisms to test, not proof that the same cause applies to a new incident.

## False health checks

`pgrep -f 'pattern'` examines complete command lines. If the pattern is passed as an argument to the waiter, the waiter can match itself and report a dead dependency as healthy. Prefer an HTTP/port check, PID file, or `pgrep -x` exact process name.

## Silent Python progress

Python stdout is block-buffered when connected through SSH or a pipe. A remote process can be healthy while its progress appears frozen. Run long Python tasks with `python -u` or explicitly flush progress output.

## Service readiness

An API server can listen before its model engine is initialized. Use the engine's documented readiness marker or execute a lightweight real request. Do not equate an open port or `/v1/models` response with full readiness without verification.

## Orphaned synchronous requests

Interrupting a client-side synchronous request may leave server-side generation running. Before resubmitting, inspect the log, queue/task store, output path, and GPU utilization.

## Remote script drift

Uploading an older script after changing the local copy can silently revert behavior. Keep the repository copy authoritative, upload immediately after validation, and never edit only the remote copy. Do not overwrite a script while it is executing.

## Storage and process failure

A live worker does not guarantee output progress. Network storage errors can stop writes while a service remains partially alive. Combine process/service health with durable state and final artifact verification.

## Interrupted waits

An interrupted wait is not evidence that the remote task failed. Perform one read-only state/output check. If still running, resume waiting or hand it to a supported background monitor; do not submit a duplicate automatically.

