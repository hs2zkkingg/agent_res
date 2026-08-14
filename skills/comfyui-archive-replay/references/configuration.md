# Configuration

Store configuration beside the project archive or in another user-selected data directory, never inside the installed skill.

```json
{
  "schema_version": 1,
  "comfy_url": "http://127.0.0.1:8188",
  "archive_dir": "archive",
  "source_dirs": ["C:\\path\\to\\ComfyUIOutput"],
  "model_roots": ["C:\\path\\to\\ComfyUI\\models"],
  "input_roots": ["C:\\path\\to\\ComfyUI\\input"]
}
```

- Resolve relative paths from the configuration file's directory.
- `archive_dir`: SQLite catalog, JSON catalog, and immutable item folders.
- `source_dirs`: folders scanned by `archive` and `watch` when no explicit PNG path is passed.
- `model_roots`: directories containing category folders such as `checkpoints`, `diffusion_models`, `text_encoders`, `vae`, `loras`, and `upscale_models`.
- `input_roots`: ComfyUI input directories used to find and preserve recognized input images and masks.
- `comfy_url`: local ComfyUI API base URL.

Create a configuration explicitly:

```powershell
python scripts/comfy_archive.py init-config --output <absolute-config-path> --source-dir <output-folder> --model-root <models-folder> --input-root <input-folder>
```

When adopting an existing archive, keep its current configuration and `archive_dir`. Add `input_roots` if absent; this is backward compatible.
