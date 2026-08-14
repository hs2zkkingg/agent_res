---
name: remote-batch-transfer
description: Prepare and transfer batches of remote files efficiently by selecting delivery fidelity, packaging many files into one archive, choosing an available platform or SSH channel, and verifying the received batch.
---

# Remote Batch Transfer

Transfer many remote files as one verified package. Avoid per-file SSH overhead and preserve the authoritative originals until delivery is accepted.

## Workflow

1. Inventory the remote inputs: count, total bytes, formats, largest files, destination, and whether originals must remain lossless.
2. Classify the delivery:
   - final/archive assets: keep originals;
   - review/contact sheet assets: a clearly labeled JPEG/WebP derivative may be acceptable;
   - already compressed media: do not transcode merely to place it in an archive.
3. Estimate packaged size and select a transport channel.
4. Present source glob/list, conversion policy, archive path, expected size, overwrite behavior, and transport channel before remote encoding, packaging, or transfer.
5. Run packaging as a remote long task with logs, a bounded timeout, and artifact verification.
6. Transfer one archive through the selected platform download channel or SCP/SFTP fallback.
7. Verify archive readability, file count, expected names, total uncompressed size, and hashes when fidelity matters.
8. Keep remote originals until the user confirms receipt; cleanup requires separate confirmation.

Read [provider-channels.md](references/provider-channels.md) when working with AutoDL, 潞晨云/丘比特, JupyterLab, shared storage, or a provider-specific download path.

## Packaging policy

- Use ZIP for broad Windows/browser compatibility unless the destination requires another format.
- For JPEG, MP4, ZIP, and other already compressed inputs, use store/no-compression mode to avoid wasting CPU.
- For final PNG or other lossless deliverables, package the originals without conversion.
- For preview-only image batches, keep full resolution by default and create JPEG quality 85 derivatives in a separate temporary directory.
- Never call a preview derivative the original or final deliverable.
- Use a manifest for large or important batches: relative path, size, and SHA-256 where practical.

## Channel selection

Prefer, in order:

1. provider/browser download channel already attached to persistent/shared storage;
2. object/shared storage with verified access;
3. one packaged archive over SCP/SFTP;
4. per-file transfer only for a tiny set or targeted recovery.

Do not assume a provider channel is unlimited or currently available. Verify it on the active environment.

## Integration

- Use `remote-long-task` for packaging, long conversion, health checks, and completion state.
- Use project-specific backup Skills when the batch is a reproducibility/archive asset rather than a one-time delivery.
- Keep provider paths and shared scripts in project/provider configuration, not in this general Skill.

## Completion report

Report:

- source count and bytes;
- any conversion and its fidelity impact;
- archive path, bytes, and manifest/hash;
- chosen channel and received destination;
- verification result;
- remote originals retained and any cleanup still pending.
