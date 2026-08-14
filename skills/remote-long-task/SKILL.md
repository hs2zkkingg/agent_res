---
name: remote-long-task
description: Run and supervise long CPU or GPU jobs over SSH with remote state files, bounded waits, health checks, idempotent restarts, and visible progress. Use for remote downloads, inference, generation, builds, or services that may outlive one SSH connection.
---

# Remote Long Task

Keep execution state on the remote host. Use one bounded remote wait instead of repeatedly sleeping and reconnecting from the local machine.

## Core workflow

1. Classify the operation:
   - Under one minute: run one synchronous SSH command.
   - One to thirty minutes: use the bundled wrapper and waiter.
   - Longer or multi-stage: start it idempotently, split it into observable stages, and use the current Codex background/wait mechanism.
2. Define a task name, remote work directory, task timeout, state file, log file, and health check before launch.
3. Upload local scripts before execution. Treat local source as authoritative; do not edit the only copy on the remote host.
4. Launch with `setsid`/`nohup`, redirect logs, and write durable state.
5. Perform one short startup check, then invoke one remote waiter with a bounded timeout.
6. Read the state and log, verify the expected artifact, and report the result.

Use:

- [`scripts/task_wrapper.sh`](scripts/task_wrapper.sh) for idempotent execution and state transitions.
- [`scripts/wait_for.sh`](scripts/wait_for.sh) for state-file completion.
- [`scripts/wait_until.sh`](scripts/wait_until.sh) for a log marker or another condition.
- [`scripts/exec_remote.ps1`](scripts/exec_remote.ps1) as a Windows orchestration template.

Read [execution-patterns.md](references/execution-patterns.md) before handling blocking APIs, multi-stage jobs, complex SSH quoting, retries, or provider-specific deployment.
Read [incident-lessons.md](references/incident-lessons.md) when diagnosing a repeated wait, orphaned task, false health check, missing progress, or remote-script drift.

## Non-negotiable rules

- Do not use a local `Start-Sleep; ssh ...` polling loop.
- Put the real task timeout on the remote host. Local and tool timeouts are only bounded fallbacks.
- Make launch idempotent. `DONE` skips, `RUNNING` attaches to waiting, and `FAIL`/`TIMEOUT` may be deliberately restarted.
- Every wait must have a health check unless the task itself is the only process being waited on.
- Avoid `pgrep -f` when the pattern can occur in the wait command itself. Prefer a port/HTTP check, PID file, or exact process name with `pgrep -x`.
- Run long remote Python programs with `python -u` so progress is not block-buffered.
- Use `BatchMode=yes` and bounded connection attempts for scripted SSH/SCP.
- Put complex remote commands in a local script, upload it, validate it remotely, and execute only a simple `bash /path/script.sh` command over SSH.
- Do not overwrite a script while a process is executing it.
- Do not start remote writes, services, GPU work, downloads, or paid generation without the confirmation required by the active project rules.

## State contract

- State file: `<WORK_DIR>/<TASK_NAME>.STATE`
- States: `RUNNING`, `DONE`, `FAIL`, `TIMEOUT`
- Task log: `<WORK_DIR>/<TASK_NAME>.log`
- Launch log: `<WORK_DIR>/<TASK_NAME>.launch.log`
- Exit codes: `0=DONE`, `2=FAIL/TIMEOUT`, `3=health failure`, `1=wait/connection error`

Do not infer success from an open port, a live process, or an SSH return alone. Verify the durable state and the expected output.

## Multi-stage jobs

Separate submission from waiting. Return the task or queue identifier promptly, then wait by stage. Keep each blocking stage short enough to provide a user update at least once per minute. If a user interrupts the wait, perform one read-only completion check; do not submit the task again automatically.

## Before execution

- [ ] Remote target and work directory are explicit.
- [ ] Launch is idempotent and state-backed.
- [ ] Task timeout and waiter timeout are bounded.
- [ ] Health check cannot match itself.
- [ ] Logs and expected output paths are known.
- [ ] Scripted SSH/SCP uses non-interactive authentication.
- [ ] Required user confirmation is current.
