# agent_res

跨项目通用 Codex Agent 配置与 Skill 源码仓库。项目专用 Skill 和项目资产不在这里维护。

## 权威边界

- `skills/manifest.json`：本仓库通用 Skill 的唯一归属清单与源码哈希。
- `skills/<skill-name>/`：完整 Skill 源码，包括 `SKILL.md`、`agents/`、`scripts/`、`references/` 和 `assets/`。
- `agent-config/AGENTS.md`：全局 Codex 指令的源码权威。
- `scripts/agent_config_sync.ps1`：全局指令的只读审计、dry-run、备份和部署入口。
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
.\scripts\agent_config_sync.ps1 deploy
.\scripts\agent_config_sync.ps1 deploy -Apply
```

部署漂移文件时，脚本会先备份旧安装副本并校验新文件的 SHA-256。修改全局指令后，新任务会更可靠地加载新的指令链。

持久本地仓库：`C:\Users\hs2zking\Documents\Codex\projects\agent_res`

原 `C:\Users\hs2zking\AppData\Local\Temp\kilo\agent_res` 暂作迁移来源快照，不再作为编辑入口。
