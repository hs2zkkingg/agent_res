# agent_res 项目规则

本仓库只维护跨项目通用的 Codex Agent 配置和 Skill 源码。

## 权威与范围

- `skills/manifest.json` 是 Skill 归属清单；每个 Skill 只能由一个 manifest 声明。
- Skill 文件夹名、manifest name 和 `SKILL.md` frontmatter name 必须一致。
- 同步整个 Skill 文件夹，不只复制 `SKILL.md`。
- mm_workflow、H3、Krea2、Sanatsu、Karaoke 等项目专用 Skill 放在对应项目仓库，不在这里形成第二权威版本。
- `kilo.jsonc` 是历史迁移资产；除非用户明确要求，不把它当作当前 Codex 配置修改。

## 修改与部署

- 优先修改本仓库权威源码，再用 `codex-skill-sync` 审计和部署到 `.codex\skills`。
- 安装目录中的变化视为 drift；比较差异后才能明确回收，禁止按修改时间自动覆盖源码。
- 部署默认 dry-run；替换漂移副本必须先备份并得到当前确认。
- 不在同步脚本中执行 Git commit、push、删除或远端操作。

## 验证

- 新建 Skill 使用 Skill Creator 标准结构，并保持 `SKILL.md` 简洁。
- 更新 manifest 中对应的完整文件夹 SHA-256。
- 检查 UTF-8、frontmatter、`agents/openai.yaml`、重复归属、凭据模式和大文件。
- 提交前分别运行同步 audit、`git diff --check` 和敏感信息扫描。

## Git 门禁

- 删除旧 Skill、副本清理、commit 和 push 都需要用户明确确认。
- 展示变更范围并按职责拆分提交；不要把项目专用 Skill 与通用 Skill 混为同一权威来源。
