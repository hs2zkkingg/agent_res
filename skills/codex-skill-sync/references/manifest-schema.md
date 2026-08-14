# Manifest schema

Each authoritative repository stores `skills/manifest.json`.

```json
{
  "schema_version": 1,
  "repository": "agent_res",
  "skills": [
    {
      "name": "example-skill",
      "path": "skills/example-skill",
      "category": "general",
      "deploy": true,
      "source_sha256": "optional deterministic folder hash"
    }
  ]
}
```

Rules:

- Use a unique lowercase hyphen-case `name` across all supplied manifests.
- Resolve `path` relative to the repository root containing `skills/manifest.json`.
- Make `path` stay inside its repository and point to a folder containing `SKILL.md`.
- Make the `name` equal the SKILL.md frontmatter name and folder name.
- Use `category` only for ownership reporting; recommended values are `general` and `project`.
- Set `deploy` to false only for a retained source that should not enter the active Codex installation.
- Calculate `source_sha256` from the sorted relative file paths and file contents of the complete Skill folder. Exclude caches and temporary files.
- Update `source_sha256` in the same reviewed change whenever the authoritative folder changes.
