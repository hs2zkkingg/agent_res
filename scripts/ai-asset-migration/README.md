# AI asset copy and verification tool

`copy_verify_assets.ps1` is the portable successor to the one-time 2026-08-15
machine migration script. It deliberately performs no junction creation,
deletion, source moves, application configuration edits, or environment-variable
changes.

The command is dry-run by default:

```powershell
.\copy_verify_assets.ps1 -PlanPath .\migration-map.example.json
```

After reviewing the resolved paths, copy and SHA-256 verify them with:

```powershell
.\copy_verify_assets.ps1 `
  -PlanPath .\migration-map.example.json `
  -AiRoot D:\AI `
  -AllowedSourceRoot C:\Users\your-name `
  -Apply
```

Plan paths support `${USER_ROOT}` and `${AI_ROOT}` placeholders. Destinations
must remain below `AiRoot`; sources must remain below one of the explicitly
allowed source roots. Existing destination files may be updated by Robocopy,
but no extra destination files are deleted.

The original local script had SHA-256
`DA0673DAF444CD02C85FFB58FBFBE695989BE7D1F3DBBD35BB354EADE2B6B5B7`.
It contained machine-specific paths and obsolete C-drive junction behavior, so
it is represented by this safer replacement rather than copied verbatim.
