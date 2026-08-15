# AI asset classification policy

Read the live `<asset-root>\README.md` first. Use this reference for the decision procedure, not as a replacement for that policy.

| Lifecycle | Destination pattern | Meaning |
|---|---|---|
| Project installation | `projects\<domain>\<project>` | Executable source tree, environment, or tool installation |
| Active work | `work\<project>\...` | Generation, training, download, stitching, or post-processing in progress |
| Application output | `outputs\<application>\...` | Direct unsorted output owned by an application |
| Accepted asset | `assets\<project>\delivery\...` | Reviewed output selected for long-term retention or delivery |
| Reusable input | `inputs\<application>\...` | Shared application input, mask, control, or reference material |
| Dataset | `datasets\<domain>\...` | Training or evaluation corpus with stable provenance |
| Model | `models\<runtime>\...` | Verified model weight used by a runtime |
| Unverified model | `models\incoming\...` | Downloaded weight awaiting source and integrity checks |
| Rebuildable cache | `cache\<tool>\...` | Data that can be downloaded or regenerated |
| Historical archive | `archives\<origin>\...` | Read-only retired source, snapshot, or provenance evidence |
| Integrity evidence | `manifests\...` | Hashes, inventories, migration summaries, and archive transaction records |
| Migration evidence | `migration\...` | Migration scripts, logs, rollback configuration, and cleanup reports |

## Decision order

1. Identify the owning project or application.
2. Identify whether the item is active, unsorted output, accepted delivery, reusable input, dataset, model, cache, or retired history.
3. Prefer the most specific existing project subtree.
4. Keep ambiguous or unreviewed material in a reversible staging category.
5. Preserve provenance and reproducibility metadata alongside the project record or global manifest.

For generated media, keep active or intermediate files in `work`, application-native unsorted results in `outputs`, and only reviewed deliverables in `assets`.

For Git repositories, preserve their own repository location and history. Do not copy a repository into `assets` merely because it contains AI-related files.
