---
name: codex-skill-sync
description: Audit, validate, back up, and deploy personal Codex Skill folders from one or more authoritative Git repositories into the local Codex skills directory. Use when reorganizing Skill ownership, checking source-versus-installed drift, installing or refreshing personal Skills, preparing Skill repository backups, or verifying that each Skill has exactly one authoritative source.
---

# Codex Skill Sync

Treat Git repositories as authoritative sources and `~/.codex/skills` as a deployment target. Never infer authority from modification time alone.

## Required model

- Keep each Skill in exactly one source manifest.
- Sync the entire Skill folder, including `agents/`, `scripts/`, `references/`, and `assets/`.
- Do not use automatic bidirectional synchronization.
- Prefer editing the authoritative source, validating it, and deploying outward.
- Treat an installed-only edit as drift. Review its diff before explicitly adopting it into a source repository.
- Do not commit, push, delete, or overwrite a drifted installed Skill without current user confirmation.

Read [manifest-schema.md](references/manifest-schema.md) when adding or changing a manifest.

## Audit

Run the bundled script with every authoritative manifest:

```powershell
python scripts/skill_sync.py audit `
  --manifest C:\path\to\agent_res\skills\manifest.json `
  --manifest C:\path\to\project\skills\manifest.json
```

If `python` is unavailable, use the current Codex workspace Python runtime. Supply `--install-root` when the installation directory is not `%USERPROFILE%\.codex\skills`.

Report these states separately:

- `MATCH`: source and installed folder hashes agree.
- `MISSING`: the Skill is absent from the installation target.
- `DRIFT`: source and installed content differ.
- `SOURCE_HASH_MISMATCH`: source differs from the recorded manifest hash.
- `UNMANAGED_SOURCE`: a source-repository Skill folder is not declared by its manifest.
- `UNMANAGED_INSTALLED`: an installed personal Skill is not owned by any supplied manifest.

Do not describe `MISSING` or `DRIFT` as a failed backup. They describe deployment state; Git status and remote tracking describe backup state.

## Deploy

Run deployment without `--apply` first. This produces a dry-run plan:

```powershell
python scripts/skill_sync.py deploy --manifest <manifest> --manifest <manifest>
```

After explicit confirmation, add `--apply` to install missing Skills. A drifted target remains protected.

To replace a drifted target, require both `--replace` and `--backup-root`. The script moves the old installed folder into the backup root before copying the source, making the operation recoverable.

Never point `--install-root` at a repository, project root, drive root, home directory, or asset archive.

## Validation and Git boundary

Before proposing a commit:

1. Run `audit` and inspect every non-`MATCH` state.
2. Run the official Skill validator against new or materially changed Skill folders.
3. Scan changed files for credentials and unexpectedly large files.
4. Show each repository's diff independently.
5. Keep commit and push as separate confirmation gates.

The synchronization script never performs Git commits or pushes.
