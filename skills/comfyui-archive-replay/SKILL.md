---
name: comfyui-archive-replay
description: Archive, deduplicate, inspect, verify, and replay local ComfyUI PNG generations while preserving embedded prompt and workflow metadata, parameters, model fingerprints, input assets, and environment information. Use when the user asks to archive new ComfyUI results, build or inspect a reproducible generation catalog, verify archive integrity or model identity, find a prior seed or prompt, replay a saved result through the ComfyUI API, or continuously monitor ComfyUI output folders.
---

# ComfyUI Archive Replay

Use `scripts/comfy_archive.py` as the deterministic engine. Keep configuration and archive data outside the skill directory.

## Locate configuration

1. Prefer an existing project `archive_config.json` when continuing an archive.
2. Otherwise use `COMFYUI_ARCHIVE_CONFIG` when defined.
3. Create a new configuration only after choosing an explicit destination. Run `init-config`; never overwrite an existing configuration without explicit approval.
4. Read [configuration.md](references/configuration.md) when creating or repairing configuration.

Pass global options before the command:

```powershell
python scripts/comfy_archive.py --config <absolute-config-path> <command>
```

Use an available Python 3 interpreter. The script uses only the standard library; do not install packages.

## Execute tasks

- Archive explicit PNGs or folders: run `archive <paths...>`.
- Archive configured output folders once: run `archive`.
- List indexed results: run `list`.
- Verify copied PNG, prompt, and workflow integrity: run `verify [archive-id]`.
- Also re-hash model files: add `--models`; warn that large models can make this slow.
- Check replay readiness without generating: run `preflight <archive-id>`. Add `--verify-models` only when exact model identity matters.
- Replay: first run `preflight`; run `replay <archive-id>` only when the user explicitly asks to start a ComfyUI generation.
- Monitor continuously: run `watch` only when the user explicitly requests ongoing monitoring. Use a recurring/background mechanism that keeps the user informed; do not leave a hidden uncontrolled process.

## Safety and reporting

- Treat archives as append-only. Do not delete, rewrite, relocate, or merge existing archive items unless explicitly requested.
- Preserve the current archive path when converting an existing project to this skill.
- Distinguish an API `prompt` graph from a visual ComfyUI `workflow`. A prompt-only archive does not mean the project workflow or open UI canvas is synchronized.
- When a task materially changes the execution graph, follow the project's `AGENTS.md`: back up the prior canonical workflow, update its `latest` workflow file, validate nodes and links, and report separately whether the open UI was reloaded.
- Do not use `--force` for replay or configuration overwrite unless the user understands the failed checks and explicitly approves bypassing them.
- Replay submits work to ComfyUI and consumes GPU resources. Listing, verification, and preflight are read-only apart from maintaining the archive index.
- Report the exact configuration path, archive path, new/existing/failed counts, and any missing model, node type, or input asset.
- Explain that matching seed is not a guarantee when model bytes, nodes, dependencies, GPU kernels, or input assets differ.

## Reproducibility boundary

The archive stores each output PNG, embedded executable prompt, embedded workflow when present, parameter summaries, discovered model hashes, ComfyUI system snapshot, and recognized `LoadImage`/`LoadImageMask` inputs. Static loader mappings may not recognize every custom node. If a workflow uses custom asset or model loaders, inspect its prompt and extend the mappings before claiming full portability.
