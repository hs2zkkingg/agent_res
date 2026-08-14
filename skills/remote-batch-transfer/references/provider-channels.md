# Provider and channel notes

These are environment-specific recovery notes. Verify current platform behavior before relying on them.

## 潞晨云 / 丘比特 / JupyterLab

The established workflow used persistent/shared storage as the handoff point and downloaded the completed ZIP through the provider's browser/JupyterLab channel. This avoided the observed variable SSH downlink performance for large batches.

Historical project paths included `/root/highspeedstorage/minmaxh3/delivery/`; treat that as mm_workflow configuration, not a default for other projects.

## AutoDL

AutoDL jobs historically used `/root/autodl-fs` shared storage. Place packages only in an explicitly confirmed persistent path. Instance-local `/tmp` or ephemeral disks are not suitable for a user download handoff unless the lifecycle is understood.

## Shared packaging scripts

The mm_workflow environment historically provided:

- `ops/pack_batch.sh`: package a glob as JPEG previews or raw originals;
- `ops/wait_gen.sh`: wait for expected output count with service health checks.

Inspect the active repository/shared copy before execution. General Skill deployment does not guarantee these project scripts exist on every server.

## Typical package choices

```text
review images     -> full-resolution JPEG q85 derivatives + ZIP store mode
final PNG         -> original PNG + ZIP store mode
video/audio       -> original compressed media + ZIP store mode
mixed archive     -> originals + manifest + ZIP
```

## SSH fallback

If the platform/browser channel is unavailable, transfer one archive over SCP/SFTP with non-interactive authentication and bounded retries. Resume when the client supports it. Avoid opening one SSH transfer per image.

## Verification

At the handoff point and after download, compare archive bytes/hash. Test the archive and compare extracted file count to the manifest before deleting any remote source or package.
