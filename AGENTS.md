# agent_res 项目规则

本仓库只维护跨项目通用的 Codex Agent 配置和 Skill 源码。

## 权威与范围

- `skills/manifest.json` 是 Skill 归属清单；每个 Skill 只能由一个 manifest 声明。
- `agent-config/AGENTS.md` 是全局 Codex 指令的源码权威；`~/.codex/AGENTS.md` 只是安装副本。
- Skill 文件夹名、manifest name 和 `SKILL.md` frontmatter name 必须一致。
- 同步整个 Skill 文件夹，不只复制 `SKILL.md`。
- mm_workflow、H3、Krea2、Sanatsu、Karaoke 等项目专用 Skill 放在对应项目仓库，不在这里形成第二权威版本。
- `kilo.jsonc` 是历史迁移资产；除非用户明确要求，不把它当作当前 Codex 配置修改。

## 修改与部署

- 优先修改本仓库权威源码，再用 `codex-skill-sync` 审计和部署到 `.codex\skills`。
- 全局指令优先修改 `agent-config/AGENTS.md`，再用 `scripts/agent_config_sync.ps1` 执行 audit、dry-run 和部署；不要直接维护安装副本。
- 安装目录中的变化视为 drift；比较差异后才能明确回收，禁止按修改时间自动覆盖源码。
- 部署默认 dry-run；替换漂移副本必须先备份。用户在当前请求中明确授权一组边界清楚的部署操作时，不逐项重复确认。
- 不在同步脚本中执行 Git commit、push、删除或远端操作。

## 验证

- 新建 Skill 使用当前安装的 Skill Creator 标准结构，并保持 `SKILL.md` 简洁。
- 使用确定性同步工具刷新 manifest 中对应的完整文件夹 SHA-256，避免手工计算和复制错误。
- 检查 UTF-8、frontmatter、`agents/openai.yaml`、重复归属、凭据模式和大文件；敏感信息扫描只报告文件和规则类型，不回显秘密内容。
- 提交前分别运行同步 audit、`git diff --check` 和敏感信息扫描。

## Git 门禁

- 删除文件、清理安装副本、commit 和 push 都需要当前用户明确授权；一条当前指令同时明确包含 commit 与 push 时可连续执行。
- `git clean`、reset、rebase、force push 和历史改写必须按具体目标单独明确授权，不用含糊的“清理”概括。
- 展示变更范围并按职责拆分提交；不要把项目专用 Skill 与通用 Skill 混为同一权威来源。
