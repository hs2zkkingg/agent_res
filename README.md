# agent_res

跨项目通用 Codex Agent 配置与 Skill 源码仓库。项目专用 Skill 和项目资产不在这里维护。

## 权威边界

- `skills/manifest.json`：本仓库通用 Skill 的唯一归属清单与源码哈希。
- `skills/<skill-name>/`：完整 Skill 源码，包括 `SKILL.md`、`agents/`、`scripts/`、`references/` 和 `assets/`。
- `agent-config/AGENTS.md`：全局 Codex 指令的源码权威。
- `scripts/agent_config_sync.ps1`：全局指令的只读审计、dry-run、备份和部署入口。
- `scripts/verify_all.ps1`：全局配置、全部 manifest、安装态和仓库变更的统一健康检查入口。
- `scripts/ai-asset-migration/`：参数化、默认 dry-run 的资产复制与 SHA-256 校验工具；不创建旧路径兼容链接。
- `config/ai-projects.json`：机器无关的 AI 工程、第三方工作树、环境与外部资产总清单。
- `scripts/verify_ai_workspace.ps1`：统一只读工作区健康检查，串联 Git、Skill、依赖基线和环境锁验证。
- `AGENTS.md`：本仓库的维护规则。
- `kilo.jsonc`：保留的 Kilo 历史配置，不作为 Codex 当前配置来源。

当前权威通用 Skill：

- `codex-skill-sync`
- `comfyui-archive-replay`
- `image-batch-generation`
- `local-bg-monitor`
- `remote-batch-transfer`
- `remote-long-task`

项目相关 Skill 由 `mm_workflow/skills/manifest.json` 管理。

## 同步模型

Git 仓库是源码权威；`C:\Users\hs2zking\.codex\skills` 是安装副本。使用 `codex-skill-sync` 执行只读审计、dry-run 和经确认的部署。禁止自动双向同步，也禁止同步工具自动 commit 或 push。

全局指令采用相同的单向模型：先修改 `agent-config/AGENTS.md`，再部署到 `%USERPROFILE%\.codex\AGENTS.md`。审计和部署示例：

```powershell
.\scripts\agent_config_sync.ps1 audit
.\scripts\agent_config_sync.ps1 audit -Strict
.\scripts\agent_config_sync.ps1 deploy
.\scripts\agent_config_sync.ps1 deploy -Apply
.\scripts\agent_config_sync.ps1 list-backups
.\scripts\agent_config_sync.ps1 restore -BackupPath <backup-file>
.\scripts\agent_config_sync.ps1 restore -BackupPath <backup-file> -Apply
.\scripts\agent_config_sync.ps1 prune-backups -Keep 10
.\scripts\agent_config_sync.ps1 prune-backups -Keep 10 -Apply
```

脚本优先使用 `CODEX_HOME`，未设置时回退到 `%USERPROFILE%\.codex`；安装目标固定为该目录下的 `AGENTS.md`。部署和恢复采用同目录临时文件校验后替换，并在覆盖前备份当前安装副本。

`restore` 与 `prune-backups` 默认只展示计划，必须显式增加 `-Apply` 才会改动文件。恢复路径必须位于受管备份目录内；清理只按明确的 `-Keep` 数量删除较旧备份。Codex 通常在新任务开始时建立指令链，因此修改全局指令后应创建新任务验证。

## 统一健康检查

默认检查同级的 `agent_res` 与 `mm_workflow` 两份 manifest：

```powershell
.\scripts\verify_all.ps1
.\scripts\verify_all.ps1 -RunTests
```

检查包含：全局 AGENTS 严格匹配、manifest 哈希无待刷新项、Skill 安装态全部匹配、manifest JSON、`git diff --check`、变更文件 UTF-8、常见凭据模式和超过 1 MiB 的意外文件。可通过 `-Manifest`、`-PythonPath`、`-CodexHome` 覆盖可移植位置；脚本只读，不执行部署、Git commit 或 push。

跨工程总检查：

```powershell
.\scripts\verify_ai_workspace.ps1
.\scripts\verify_ai_workspace.ps1 -Strict
```

默认检查权威仓库是否与远端一致、第三方仓库是否仍位于锁定 commit、外部资产根目录、Skill/Agent 配置健康度和四套本地工具链关键版本。Kohya 等已知不可启动的环境会报告 `WARN`；`-Strict` 会把警告提升为失败。该脚本不启动模型、CUDA、训练、推理或 ComfyUI。

持久本地仓库：`C:\Users\hs2zking\Documents\Codex\projects\agent_res`

原 `C:\Users\hs2zking\AppData\Local\Temp\kilo\agent_res` 暂作迁移来源快照，不再作为编辑入口。
