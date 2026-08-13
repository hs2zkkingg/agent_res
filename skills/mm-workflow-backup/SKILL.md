---
name: mm-workflow-backup
description: mm 工作流资产备份管理：本地/git/共享盘三副本矩阵、资产上传流程（脚本→mm_workflow 仓库、提示词→h3/prompts）、备份触发时机（收工前/重大变更后/平台风险时）与校验。适用于备份与同步脚本、skill、文档、资料集资产。
---

# Skill: mm-workflow-backup

# mm-workflow 备份管理（2026-08-13 定案）

## 核心原则

- **小文件必须多副本**（脚本/文档/资料集/配置）：本地备份目录 + git 仓库 + 共享盘，三处冗余
- **模型权重无法本地备份**（199G）：靠共享盘持久 + `dl_*.sh` 脚本重建能力
- **云平台随时可能关闭**（潞晨云 H800 下架教训）：数据抢救优先级 = 脚本/文档 > IR 资料集 > 成品视频 > 模型权重

## 备份资产清单（三副本矩阵）

| 资产 | 本地 | git 仓库 | 共享盘 |
|---|---|---|---|
| skills + AGENTS.md + kilo.jsonc | `Desktop\agent_backup\` | — | — |
| 工程脚本 | `Temp\kilo\` + `Desktop\script_backup\` | `mm_workflow` | `ops/` |
| IR 资料集 vN | `Temp\kilo\ir_archive\` | `mm_workflow/h3/prompts/` | `uploads/maid/ir/` |
| 文档（HANDOFF/PITFALLS） | 本地 | `mm_workflow/docs/` | `notes/` |
| 成品视频 | 按需下载 | — | `delivery/` |

git 仓库：`https://github.com/hs2zkkingg/mm_workflow.git`（本地 `Temp\kilo\mm_workflow`）

## 备份时机（触发条件）

1. **每天收工/关机前**：HANDOFF 同步共享盘 + 本地备份刷新
2. **重大变更后**（skill 更新 / 新脚本 / 新资料集版本）：立即备份
3. **平台风险时**（下架/关闭消息）：全量检查三副本

## 备份动作流程

```
1. 本地备份目录复制（agent_backup / script_backup / ir_archive）
2. git 提交推送（脚本 → mm_workflow 分类目录; prompts → h3/prompts/vN/）
3. 共享盘同步（scp HANDOFF + 关键脚本 + 资料集）
4. 校验（grep 关键内容 / 文件数 / sha256 大文件）
```

## 资产上传流程（2026-08-13 补全）

**脚本资产上传**（本地 → git）：
1. 更新 `tools/organize_repo.py` 的 `FILES` 映射（新脚本 → mm_workflow 分类目录）
2. `python tools/organize_repo.py`（自动复制 + API key 剥离）
3. `git add -A && git commit && git push`（提交前 grep `sk-` 验证）

**提示词资产上传**（ir_archive → git）：
1. 新版本 vN 归档三件套后，运行 `python tools/repo_prompts.py`（自动按版本分组 → `h3/prompts/vN/` + PAIRING.md）
2. `git add -A && git commit && git push`

**完整链路**（新资料集版本为例）：
```
IR 生成 vN → ir_archive 归档三件套 → repo_prompts.py → git commit+push
          → scp 共享盘 uploads/maid/ir/ → 校验三处一致
```

## git 提交纪律

- 新脚本入 `mm_workflow` 分类目录（h3/krea2/comfy/docs），commit + push
- **API key 严禁提交**：一律 `os.environ.get("MINIMAX_API_KEY")`；提交前 grep `sk-` 验证
- 大文件（模型/视频/图片）走 .gitignore，不进库

## 检查清单

- [ ] skill/AGENTS 变更 → agent_backup 同步
- [ ] 新脚本 → git 提交 + 共享盘 ops/ 同步
- [ ] 新资料集版本 → ir_archive + git h3/prompts/ + 共享盘三处
- [ ] 关机前 → HANDOFF 同步共享盘 + 本地刷新
- [ ] 提交前 → grep `sk-` 无 API key
