---
name: ai-asset-organizer
description: Classify, plan, archive, verify, and catalog local AI engineering assets under the configured AI asset root. Use when Codex needs to organize generated media, project outputs, models, datasets, inputs, caches, archives, or project installations; move accepted work into long-term storage; audit misplaced assets; or produce a safe dry-run before copying or moving files.
---

# AI Asset Organizer

Organize assets by lifecycle while keeping code authority, working data, final assets, and historical evidence separate.

## Required workflow

1. Resolve the asset root from `AI_ASSET_ROOT`; default to `D:\AI` only on this Windows workspace.
2. Read `<asset-root>\README.md` completely. Treat it as the current classification policy; stop if it is missing or conflicts with the requested destination.
3. Determine whether the request is inventory, dry-run planning, copying, moving, or cleanup. Inspection and planning do not authorize writes.
4. Inspect every source path, type, size, reparse-point state, repository status when applicable, and existing destination. Do not classify from a filename alone when content or provenance changes the answer.
5. Choose the lifecycle destination using [archive-policy.md](references/archive-policy.md). Keep an uncertain item in `work` or `models\incoming`; do not guess a permanent category.
6. Run `scripts/archive_ai_assets.ps1` without `-Apply` to validate containment, collisions, file counts, and byte totals.
7. Show the source, proposed destination, lifecycle reason, file count, bytes, collisions, manifest destination, and whether the source would remain or be removed.
8. Apply only when the current request clearly authorizes the proposed write. Use `-Apply` to copy and verify. Add `-RemoveSource` only when the user explicitly authorizes removal after verification.
9. Require source/destination SHA-256 equality before reporting success. Preserve the generated JSON manifest under `<asset-root>\manifests`.
10. Re-read the destination and manifest, then report copied, verified, removed, skipped, conflicting, and unverified items separately.

## Safety boundaries

- Default to dry-run. Never overwrite an existing destination item; stop on every collision.
- Never move or delete a Git repository, model library, dataset, archive, backup, or only known copy without explicit current authorization.
- Treat Git commit, push, source deletion, remote writes, service operations, and paid or GPU work as separate effects unless the current request clearly authorizes them together.
- Reject a destination outside the configured asset root and reject a destination nested inside a source directory.
- Reject reparse points by default. Do not create C-drive compatibility shortcuts or junctions.
- Keep credentials out of files, manifests, logs, documentation, and Git. Do not echo secret contents.
- Treat `manifests` as integrity evidence, not as a backup. Important assets still need an independent backup location.
- Do not turn this Skill into an implicit background watcher. Scheduled monitoring or unattended moves require a separately reviewed automation task.

## Routing

- Use `mm-workflow-backup` after organizing material that belongs to the `mm_workflow` reproducibility archive or backup set.
- Use `comfyui-archive-replay` for ComfyUI PNG metadata catalogs and replayable generation archives.
- Keep project-specific rules in the project repository. This Skill owns only the cross-project classification and safe filesystem procedure.

## Helper script

Plan without writing:

```powershell
& scripts/archive_ai_assets.ps1 `
  -SourcePath D:\incoming\scene-01.mp4 `
  -DestinationDirectory D:\AI\assets\mm_workflow\delivery\maid_long
```

Copy, verify, and write a manifest after authorization:

```powershell
& scripts/archive_ai_assets.ps1 `
  -SourcePath D:\incoming\scene-01.mp4 `
  -DestinationDirectory D:\AI\assets\mm_workflow\delivery\maid_long `
  -Apply
```

Use `-RemoveSource` only for an explicitly authorized verified move.
