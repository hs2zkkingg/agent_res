---
name: minimax-h3-ref2va
description: MiniMax H3 Ref2VA 多参考图工作流：角色资产库 → Context IR 生成提示词 → 多图输入出片，含参考图数量与耗时关系、性能优化方案。适用于潞晨云 4 卡 H800 + vLLM-Omni combined serve 出片。
---

# MiniMax H3 Ref2VA 多图工作流

> **官方 API 长镜头拼接（>15s 一镜到底，A-B-A 三明治方案）见独立 skill：`minimax-h3-longtake`**（2026-08-13 定案）。本 skill 只覆盖本地 vllm-omni 出片。

## ⚠️ 部署规范（2026-08-11 决策）

**1. 默认只跑 ref2va，不加载 FL2VA**：
- 部署用 **ref2va 单 partition**（`--task-type ref2va` 或 `--model-variant ref2va`），**不加载 FL2VA DiT**
- 省 ~66G 内存 + 加载时间减半
- 不跑 t2va/fl2va 任务（当前不需要）

**2. AdaLN：已还原，勿再启用（2026-08-11 决策）**：
- 目标曾是跳过 AdaLN 13B 参数（省 ~26G/transformer）——但 **PR #5783 省的是稳态显存，与"减少首次加载时间"目标不符**（ref2va-only 实测显存 12G/80G 用不上；首次加载反而略增建表）
- **状态**：✅ 已还原（官方 main 原版覆盖 denoise_loop/transformer/layerwise_backend + 删 adaln_schedule_cache.py），无 ADALN 环境变量残留，import 验证通过
- 还原方法：gh-proxy 下载官方 main tarball 提取原版覆盖（patch 反向在混合状态下不可靠；git apply 对 gitignore 目录无效——**直接上游覆盖最干净**）
- patch 备份：`/tmp/pr5783.patch`（CPU 机，未来若要 combined 撞显存再议）

## 完整工作流（2026-08-11 定型）

```
角色资产库 (uploads/<角色>/)
  front.png / side_30.png / profile.png / front_detail.png / back.png
  action_v1/*.png (动作参考)
        ↓
Context IR 云端 API (/v2/h3_context_ir)   ← 本地可调, 无需 GPU
  多视图图 + 镜头文本 → 结构化增强提示词
        ↓
H3 Ref2VA 出片 (vLLM-Omni, 4 卡 H800)
  input_references 多图 + IR 提示词 + 竖屏 → 视频
        ↓
共享盘 uploads/<角色>/ref2va_*.mp4 → 丘比特下载
```

### 三个环节
1. **角色资产**：多视图设定图（正/侧/背/面部 + 动作参考），命名规范见下
2. **Context IR**（云端，本地脚本调用）：理解多视图 → 生成 `<Picture N>` 结构化提示词（subject_definitions / detailed_description / soundscape / music）
3. **Ref2VA 出片**（本地 4 卡 serve）：`input_references` 多图 + IR 提示词

## 角色资产命名规范

```
uploads/<角色名>/
├── front.png           # 正面全身 (身份锚点, 必选)
├── front_detail.png    # 面部/上衣细节
├── side_right_30.png   # 30° 前侧 (裙撑轮廓)
├── profile.png         # 90° 纯侧
├── back.png            # 背面
├── action_v1/          # 动作参考 (端托盘/行走/开门/屈膝礼等)
└── stocking/           # 细节参考
```
- 全英文小写 + 下划线，避免路径编码问题
- `front.png` 固定名（脚本直接引用）

## ⚠️ 资产命名不可依赖（2026-08-11 强调）

**文件名仅供参考，选择参考图必须以实际图片内容为准**：
- 尤其是 `action_v1/*` 这类批量动作图，文件名（如 `09_walking_front_holding_silver_tea_tray.png`）可能与实际画面不符（AI 生成、批量重命名、人工整理等都可能造成偏差）
- 选图前**必须查看图片实际内容**（打开图片确认），再决定是否匹配当前镜头
- 镜头匹配示例：要"端托盘行走" → 打开 action_v1 候选图确认确实在端托盘+行走，而非仅凭文件名
- 用户提供的资产目录命名可能不规范，**不要假设文件名语义**

## ⚠️ 提交前二次确认（强制，2026-08-11）

**每次生成任务提交前，必须先向用户展示确认清单，用户明确确认后才开始真正生成**：

```
=== 生成任务确认 ===
【参考资产】(全部引用的多媒体资产, 含 <Picture/Video/Audio N> 标签与完整路径)
图片:
  1. <Picture 1> front.png                 (uploads/maid/front.png, 正面全身-身份锚点)
  2. <Picture 2> side_right_30_detail.png  (uploads/maid/side_right_30_detail.png, 30度前侧细节)
  3. <Picture 3> 03_seated_....png         (uploads/maid/stocking/..., 坐姿掀裙吊带袜)
视频: (若有)
  1. <Video 1> xxx.mp4                     (路径)
音频: (若有)
  1. <Audio 1> xxx.wav                     (路径)

【生成参数】
- 时长: 15 秒
- 分辨率: <W>×<H> | 面积≈1M | 比例 <主图比例, 如 2:3> (按输出分辨率计算规范: 主图比例+32对齐)
- 步数: 25（默认）| fps: 24 | flow_shift: 12
- 提示词: <IR prompt 文件名, 简述内容>
- 输出: /root/highspeedstorage/minmaxh3/delivery/maid/xxx.mp4
=== 确认后开始 ===
```

**执行规则**：
- **show 所有引用的多媒体资产**（图/视频/音频），带 `<Picture/Video/Audio N>` 标签 + 完整路径 + 用途——不只列图片文件名
- **报告分辨率 + 比例参数**（2026-08-12 定）：确认清单必须含 分辨率 W×H + 面积(≈1M) + 比例(主图) + 对齐信息，便于核对是否按规范计算
- 列出**主要生成参数**（时长/分辨率/步数/采样参数）
- 列出**输出路径**
- **用户说"开始/可以/确认"后才提交**；未确认绝不启动（用户曾明确批评过擅自启动）
- 脚本先上传就绪但不运行，确认后只跑启动命令

## ⚠️ 出片启动强制序列（2026-08-11 违反教训，不可跳过）

**每次出片的唯一正确动作序列**，顺序执行，少一步都不允许启动：

```
1. 上传/更新出片脚本（scp，不运行）
2. 输出确认清单（见上模板，含实际文件名+参数+输出路径）
3. 等用户明确确认
4. 后台启动: setsid nohup bash <脚本>（日志+输出文件就位）
5. 完成检测: wait_for.sh 等输出文件出现 + HEALTH_CMD=serve 进程（见 remote-long-task）
6. 汇报: 输出路径 + ffprobe/质量检查结果
```

**违反案例（2026-08-11 实发，禁止重犯）**：
- ❌ 未经确认直接 curl 提交出片
- ❌ 本地同步阻塞 `curl /v1/videos/sync` 等 17 分钟（应后台提交 + 状态检测）
- ❌ 出片完成才想起编码 profile 未验证（应先确认编码配置）

**检查自身**：启动出片命令前 5 秒自问——①用户确认了吗？②是后台启动吗？③等待用的是 wait_for.sh 吗？④编码档位确认了吗？任一为否 → 停下。

## ⚠️ 异步 API 出片（2026-08-12 定案，sync 无法取消）

- **出片用异步 API `/v1/videos`**（POST 返回 video_id → 轮询 `GET /v1/videos/{id}` → 下载 `GET /v1/videos/{id}/content`）
- **sync API（`/v1/videos/sync`）禁止使用**：任务不注册 VIDEO_STORE，客户端断开后服务端孤儿任务**无法取消**（白耗 GPU）
- **取消机制**：异步任务可 `DELETE /v1/videos/{video_id}`（服务端 task.cancel()），脚本 `ops/cancel_video.sh <video_id>`；出片脚本会打印 VIDEO_ID
- 出片脚本 `ops/run_ref2va_15s_3img.sh` 已改造为异步版（提交+轮询+下载+打点）
- ⚠️ **取消机制真相（2026-08-12 实测）**：DELETE 只取消 API/元数据层（任务从 store 移除、请求 abort），**engine 生成循环不中断**——进度条 abort 后继续跑完（3/9→6/9 实证），**GPU 直到任务自然结束才释放**。sync 与 async 在"白耗 GPU"上本质相同
- **对策**：任务步数尽量短（10 步 3 分钟白耗可控）；发起前确认清楚，避免跑错任务白耗


## ⚠️ 出片打点（2026-08-11 固化，与启动打点对称）

**出片脚本内置打点，完成后输出耗时**：
- `run_ref2va_15s_3img.sh` 含打点：提交时间戳 → curl `-w` 网络传输耗时（含服务端生成+编码）→ 完成时间戳 → **输出 `出片总耗时: Xs`**
- 服务端侧明细（vllm 日志，可选）：`stage_gen_time_ms`（去噪生成）+ `Video response encoding (MP4 bytes)`（编码耗时）
- 完成后必 show：`出片总耗时` + 输出文件 + `ffprobe` 编码档位（High 验证）
- 等待脚本 `wait_gen.sh` 同样带健康检查（serve 端口 8091），崩溃退出码 3


## Context IR 用法（本地，无需 GPU）

```python
# 本地脚本: 多图 + 镜头文本 → 增强提示词
# API: POST /v2/h3_context_ir
# body: {model: MiniMax-H3, content: [text + N×reference_image], duration, ratio}
# 轮询: GET /v2/query/video_generation/{task_id} → content.prompt
```
- 脚本: 本地 `h3_ir_multimg.py` / `h3_ir_15s.py`（API key 内置）
- 关键: 用多视图图（front/side_30/profile/front_detail）让模型理解角色 → 输出结构化提示词
- **IR 输入 = scene brief（镜头文本，脚本内 TEXT 常量或独立文本文件）；IR 输出 = 5 段式 prompt（ir_prompt_*.txt）**

## ⚠️ IR 输入/输出维护铁律（2026-08-11 用户强调，强制）

0. **IR 输入 = Base 输入（同一套参考图，2026-08-11 官方契约定案）**：
   - IR 提交的参考图 = Ref2VA 出片提交的参考图 = **同一套**（≤9 张），禁止两套
   - 依据：官方 `ref-en.txt` 契约——prompt 的 `<Picture N>` 标签对应 Base 端必须提供的参考图，输出规则明确 "avoid unresolved reference labels"；IR 与 Base 输入上限完全一致（图≤9 / 视频≤3 / 音频≤3 / 总数≤12）
   - 可加补充视图（profile/back 等）增强角色理解，但**必须出片时一并提交**（Base = IR 全集），否则 `<Picture N>` 悬空
1. **永远不要直接修改 Context IR 输出的 prompt**（5 段式 `ir_prompt_*.txt`）。IR 输出是 API 生成物，人工改会破坏一致性、不可追溯。
2. **每次修改提示词 = 修改 IR 输入的 scene brief**（`h3_ir_*.py` 的 TEXT / brief 文本文件）→ **询问用户是否调用 API 重新生成**，用户确认后才调 `/v2/h3_context_ir`。
3. **调 IR API 前必须展示确认清单（含全部输入资产）**，用户确认后才调 `/v2/h3_context_ir`：
   ```
   === IR 任务确认 ===
   【修改内容】brief 变更摘要（如 [收尾] 段：躺椅闭眼 → 脱鞋+伸展+脚底朝镜头）
   【输入资产】(全部引用的多媒体资产)
   图片:
     1. <Picture 1> front.png               (uploads/maid/front.png, 正面全身-身份锚点)
     2. <Picture 2> side_right_30_detail.png (uploads/maid/side_right_30_detail.png, 30度前侧细节)
     ...（实际提交顺序 = <Picture N> 编号）
   视频: (若有) <Video N> 路径+用途
   音频: (若有) <Audio N> 路径+用途
   【参数】duration=15 | ratio=<主图比例> | model=MiniMax-H3
           | 输出分辨率: <W>×<H> (面积≈1M + 主图比例 + 32对齐)
   【输出】outputs/ir_prompt_15s_vN.txt
   === 确认后开始 ===
   ```
   - **输入资产列表 = refs 清单「IR 输入参考」段的顺序**（提交顺序 = `<Picture/Video/Audio N>` 编号 = 保序锚点）
   - IR 输入资产必须与后续 Base 出片同一套（第 0 条规则）
4. **生成记录归档 = 三组数据一套（版本化，保证合规可追溯）**：
   - 每个版本 vN 归档**三个文件**（同 N 配对）：
     1. `briefs/brief_<场景>_vN.txt` — **原始提示词**（scene brief，IR 输入）
     2. `refs/refs_<场景>_vN.txt` — **原始参考资产清单**（文件路径列表 + `<Picture N>` 标签对应；音/视频同理记录路径，不复制文件）
     3. `outputs/ir_prompt_<场景>_vN.txt` — **IR 输出 5 段式 prompt**
   - `PAIRING.md` 为索引（版本/日期/说明/三组文件/出片产物）
   - 归档目录：本地 `Temp\kilo\ir_archive\`，共享盘 `uploads/maid/ir/`
   - 每次生成：归档新 brief（vN）→ 调 API → 输出存 vN → 写 refs 清单（同版）→ 更新 PAIRING
   - 出片脚本引用最新版输出；旧版保留可追溯
5. **保序校验（模型不自校验，必须我们自己校验，2026-08-11 定案）**：
   - IR/Base 模型**不会识图核对 `<Picture N>` 标签**（黑盒），保序完全依赖我们的提交顺序
   - 校验**三类资产**：图片 `<Picture N>` / 视频 `<Video N>` / 音频 `<Audio N>`
   - 每次生成归档后跑：`python ops/verify_ir_pairing.py <refs清单> <ir输出> [base出片脚本]`
     校验：① IR 输出各类标签 ⊆ 对应输入（不超界）② Base 提交顺序 = refs Base 段记录 ③ Base 提交图 ⊆ IR 输入（IR=Base 规则）
   - 返回码 0=PASS / 1=FAIL；**FAIL 禁止出片**，先修正顺序/补齐资产
   - refs 清单顺序 = 提交顺序 = 保序锚点（`<Picture/Video/Audio N>` 按提交顺序编号）
- 现状基线：v1/v2 为历史版本（IR 4 图 ≠ Base 3 图，不合规），refs 清单**如实记录**；v3 起按第 0 条规则（IR = Base 同一套）

## ⚠️ 镜头风格必须显式要求（2026-08-11 踩坑）

**Context IR 默认输出多分镜（[Shot 1..N] + 时间切点），会导致视频频繁切换镜头**。

- 实测：未要求时生成 5 个 Shot，出片大量切换，用户不满意
- **一镜到底必须在 IR 输入文本中显式声明**：
  - `single continuous take` / `uninterrupted shot`
  - `without any camera cuts`（无镜头切换）
  - `不要用 [Shot N] 分镜`，用连续摄影机运动（跟拍/摇移/推拉/弧线）衔接
- 一镜到底版 IR 输出: `ir_prompt_15s.txt`（[Shot 1] 单镜头贯穿 15s）
- 若想要"少切换"而非纯一镜，可指定"≤N 次切换"或用场景衔接提示

## Ref2VA 出片要点（4 卡 H800）

### 起 serve 参考文件（2026-08-11 定型，只认这些）

### 输出分辨率计算规范（2026-08-12 用户定案，面积预算方案）

**ComfyUI 方案 B 等价实现（2026-08-13 确认）**：ComfyUI 原生 `ResolutionSelector` 节点（`comfy_extras/nodes_resolution.py`）算法与本规范逐字等价：
```python
total_pixels = megapixels * 1024 * 1024
scale = sqrt(total_pixels / (w_ratio * h_ratio))
width  = round(w_ratio * scale / multiple) * multiple   # multiple=32
height = round(h_ratio * scale / multiple) * multiple
```
- 支持 8 种比例：1:1 / 2:3 / 3:2 / 3:4 / **4:3** / 9:16 / 16:9 / 21:9
- 验证：4:3 + 1.0MP → 1184×896（与本规范手动计算结果一致）
- 方案 B 出片：用户指定比例 → ResolutionSelector 选比例+megapixels → 自动算宽高，无需自写计算


- **本质约束 = 像素面积 ≈ 1M**（官方 `MINIMAX_H3_OUTPUT_MAX_PIXELS = 768×1344 ≈ 1,032,192`）。社区 #65 证实遵循度随**像素量**（token 数）上升而下降——限制面积即控制遵循度，短边 768 只是官方 1M 面积+9:16 的实现特例，非本质
- **比例必须用户显式指定（2026-08-13 修正）**：patch 后参考图与画布已解耦（模型只看图内容），**视频比例不能通过输入主图探测**——出片确认清单必须含用户指定的宽高比（如 16:9 / 2:3 / 9:16）
- **用户不指定比例 → 报错提醒，不出片**（不得默认取主图比例，也不得悄悄用 16:9）
- **算法**（area≈1,032,192，r=主图宽/高，32 对齐）：
  - 竖图 r<1：`H=round32(sqrt(area/r))`, `W=round32(H*r)`
  - 横图 r≥1：`W=round32(sqrt(area*r))`, `H=round32(W/r)`
  - `round32(n)=round(n/32)*32`（vllm `_align_multiple` 同款）
- 示例：主图 2:3 → **832×1248**；主图 9:16 → **768×1344**（官方规格）；主图 16:9 → **1344×768**；主图 1:1 → 1024×1024
- ⚠️ vllm-omni 显式传 width/height 时只校验 32 对齐 + 长宽比 [1:4,4:1]，**绕过 short_edge=768 强制**——按上式算出的尺寸可跑；面积允许因对齐略超/略低于 1M（round 容差）

### 分辨率与动作能力边界（2026-08-12 社区实证 HF #65/#59）
- **分辨率甜点 = 短边 768**（官方规格），但社区实测（HF #65, 4xB300）：**prompt 遵循度随分辨率上升显著下降**——352-416p 几乎完美遵循（镜头/角度/位置/禁令），768p 明显变差。**不要盲目上调分辨率**（如 896×1344 短边 896），越高遵循越差；增加步数只改善视觉不修复结构
- **精细动作是模型短板**（HF #59，2026-08-12 扩充）：
  - 脱带袢/魔术贴的鞋、脱衣、解扣、脱袜等动作呈现"虚空操作"/不自然
  - **手部生成短板**：双手同时动作（一手揉胸+一手摸私处）→ **三只手/extra limbs**（NSFW v2 实测）；单手动作更稳
  - **动作空间逻辑混乱**：交叉腿脱鞋时"翘左腿却脱右脚鞋"（腿脚对应关系掌握差）
  - H3 通病，非 prompt/参数可完全解决；缓解：特写镜头 + 减动作密度 + **单手动作优先**（避免双手同时）
- **输出比例**：按「输出分辨率计算规范」（面积≈1M + 主图比例 + 32 对齐）；2:3 主图 → 832×1248（勿用 768×1344 配 2:3 资产，会拉伸）

> **脚本位置**：所有运维脚本在共享盘 `ops/` 目录（2026-08-11 迁移整理），日志在 `logs/`，打包产物在 `archive/`，文档在 `notes/`。

| 文件 | 用途 | 说明 |
|---|---|---|
| `ops/run_h3_4gpu_ref2va_adaln.sh` | **主启动脚本** | ref2va-only + **内嵌预热**（无 AdaLN） |
| `ops/run_h3_4gpu_ref2va_base.sh` | A2 验收基线 | 同主脚本但 AdaLN cache OFF（sed 生成） |
| `ops/start_gpu_serve.sh` | **统一入口** | `bash ops/start_gpu_serve.sh [脚本名]`，端口 8091 探测已运行，默认主脚本 |
| `ops/run_h3_4gpu_luyun.sh` | ⚠️ 已过时 | 旧 combined 版，勿再用（ops/start_gpu_serve.sh 已不再指向它） |

| `ops/boot_report.sh` | **就绪判定+打点报告** | `bash ops/boot_report.sh`：等待 engine 真正就绪 + 输出启动各阶段耗时表 |

**开机流程（每次）**：
```
1. 挂载共享盘 + 更新本地 .ssh/config 端口
2. bash ops/start_gpu_serve.sh          # 预热(内嵌) + 启动 + 日志
3. bash ops/boot_report.sh              # 等待就绪(10min) + 输出打点耗时表
4. 出片（见「出片启动强制序列」）
```
- **就绪判据 = 日志出现 `AsyncOmniEngine initialized`**。⚠️ 不要用 `/v1/models` 200 判就绪——**那是假就绪**（API server 先监听端口，engine 仍在后台初始化，实测提前数分钟返回 200）
- **预热已内嵌但按平台/内存配额决策**（2026-08-13 定案）：
  - ✅ **预热有效条件**：内存配额充裕（>模型文件 + DLO 权重需求，如潞晨云 2TB）且本地盘/Lustre 高速盘——实测 827s→242s
  - ❌ **内存配额不充足时不要预热**（如 AutoDL 100G）：预热 page cache（需 ~133G）与 DLO offload 权重（~60G 不可回收）抢配额，page cache 可回收会被挤掉 = **预热白做 + 拖慢启动**——直接跳过预热冷读加载
  - 判断式：`内存配额 < 预热文件大小 + DLO 权重内存` → 跳过预热（serve 脚本已按平台自适应：luyun 预热 / autodl 跳过）
  - **AutoDL/AutoFS 默认冷读不预热（2026-08-13 定案）**：实测 223MB/s 冷热无区别（FUSE 网络盘每读都走网络，page cache 无效）——预热 10 分钟纯浪费，直接冷读加载
  - ref2va-only 预热排除 FL2VA/transformer（只预热 ~133G）；AutoDL AutoFS 带宽低（读 223MB/s / 写 83.5MB/s）
- 同次开机多次重启不重复预热（page cache 仍在）
- 实测打点（2026-08-11，开机后）：预热 65s + encoder 72s + transformer TP 166s + 收尾 24s = **总 327s**
- 服务端模型：`h3_fl2va_hf`（FL2VA + Ref2VA 分区，Ref2VA 组件为软链指向 FL2VA）
- **本地 serve**：ref2va 单 partition（`--task-type ref2va`），端口 8091
  - **加载范围确认**（源码 pipeline_minimax_h3.py:581 实锤）：`model_path = model_root / ("Ref2VA" if partition=="ref2va" else "FL2VA")` —— ref2va 只加载 **Ref2VA 目录**（transformer 62G + 共享组件 text_encoder 67G/VAE ≈ 133G），**FL2VA/transformer 66G 不加载**
- **多图**：`input_references=`（复数，可重复传多张）**≤12 张**（本地上限，官方 API ≤9）
- **单图**：`input_reference=`（与复数互斥，二选一）
### 本地生成默认后处理流程（2026-08-13 定案, 02:30 策略修正）
- **默认出片输出双格式**：
  1. **无损中间格式**（H.264 crf=0, `extra_params.video_codec_options={"crf":"0"}`）——供后续超分插帧
  2. **H.264 High 预览格式**（正常 crf, 文件小）——供用户快速评估
- **评估门控（超分插帧不自动跑）**：
  1. 通知用户下载**预览格式**评估
  2. 用户评估通过且**显式告知**进行超分插帧 → 才基于**无损数据**执行
  3. 流程：2x 超分（RealESRGAN_x2plus）→ 2x 插帧（RIFE 24→48fps）→ 最终交付编码（H.264 High, 正常 crf）
  4. 完成后通知用户下载成品，并**询问是否删除原始无损视频**（文件大 ~100-500MB，用户确认才删）
- 重编码耗时很短（x264 压缩 ~20-60s, 无模型推理），预览格式零额外成本
- 依据：插帧/超分对压缩伪影敏感，基于无损数据处理质量最优；但超分插帧耗时（3-18 分钟），先预览评估再后处理避免浪费

### 官方 API 端到端生成调用策略（2026-08-13 定案）
- 官方**无一次调用包圆的 API**（IR 与生成是独立接口）；"端到端效果" = 显式两步或一步直喂
- **质量最佳策略**（本质目的：生成质量最佳）：
  1. **已有原始提示词对应的 IR 输出** → 生成 API 直接提交 IR 输出（2K 12 元 / 768P 7.5 元）
  2. **只有原始提示词（brief）+ 图片**（无 IR 输出）→ **先走 IR（~0.2 元）再走生成**（0.2 + 12 元）
- 一步直喂原始 brief 也可（官方内部理解），但官方文档明确 IR 输出"更完整"——直喂效果弱于显式 IR
- 计费备忘：IR 输入 5.8 元/M + 输出 23 元/M tokens；生成 2K 0.80 元/s、768P 0.50 元/s

- **⚠️ 人物压扁根因 + 本地修复（2026-08-13 定案, 对应 vllm-omni issue #5883）**：
  - **根因**：`entrypoints/openai/serving_video.py` 共享路径**无条件把参考图 LANCZOS 拉伸到请求的 width×height**——H3 pipeline 自己的 aspect-preserving 处理（`_reference_image_shape` 保持比例 + Qwen pad）被共享层预拉伸**提前破坏** → 模型收到已变形图 → 生成压扁
  - **本地已 patch**：`applies_own_geometry = "minimax" in model_name.lower()`——H3 跳过共享层预 resize，走自己的保持比例路径（官方托管端同款行为）；备份 `serving_video.py.bak_aspect`；待出片验证（2:3 参考图 + 16:9 画布不压扁）
  - 官方 API 无此问题（托管端无预拉伸）——与"官方 adaptive 出 16:9 效果好"相互印证
  - 正确问题定义（用户原话）：**视频比例与输入图比例解耦，模型只看输入图内容**
- **宽高比策略分环境（2026-08-13 实测修正）**：
  - **本地 vllm-omni**：比例尽量绑主图（参考图方向）——本地 `ref_image_size` 处理会把参考图拉伸到生成分辨率，比例不匹配 = **人物压扁**（实测踩坑），故输出分辨率按主图比例算（见「输出分辨率计算规范」）
  - **官方 API（ratio=adaptive）**：**信任官方自适应**——官方托管端处理参考图比例无拉伸问题，2:3 主图 + adaptive 实测出 landscape 且效果很好（task 430076510716337）；官方 adaptive 由输入综合判断比例，不必强绑主图
- **宽高比必须匹配参考图方向**（本地 vllm-omni 规则）：
  - 竖版参考图（2:3）→ 输出 **768×1344**
  - 横版 → 1344×768
  - 用错方向会**人物压扁**（踩过坑）
- **时长**：官方 4-15 秒，本地 `extra_params.duration`
- **seed（2026-08-12 决策）**：**默认随机**（`$((RANDOM*32768+RANDOM))`，脚本未传参时），**特殊说明才固定**（对比/复现场景，如 v1↔v2 同 seed 验证 prompt 改动）。本地 vllm-omni 支持 seed（torch.Generator 播种视频+音频 latent，默认 42），官方 API 无 seed 参数
- **参数（2026-08-12 定案，25 步存疑待验证）**：默认 25 步，但 **v4 832×1248 实测 25 步镜头流转异常**（50 步正常）。待对照实验：固定 v4/832×1248/seed，50 步验证镜头恢复 → 恢复则回 50 步。**未定论前出片优先 50 步**（官方基准）。出片脚本步数已参数化：`bash run_ref2va_15s_3img.sh [host] [seed] [steps]`。flow_shift 12 / cfg 1 系 / fps 24
- 出片脚本: `ops/run_ref2va_multimg.sh`（单图）/ `ops/run_ref2va_15s.sh`（多图 15s）/ `ops/run_ref2va_15s_3img.sh`（3 图减量版）

## ⚠️ 参考图数量 ↔ 耗时关系（2026-08-11 实测+调研）

**结论：参考图越多越慢，两个成本中心：**

1. **编码阶段（线性）**：每张图过 Qwen3-VL-32B+VAE，实测单图 +13.9s（4×MI300X）
2. **去噪每步 attention（近似二次，主因）**：
   - H3 开源版是 **full attention**（无 sparse 兜底，托管 API 才有）
   - attention ∝ L²，参考 token 每步作为 KV 全量查询
   - 9 张 768p 图 ≈ +9000 token，单步 +~20%（f_attn≈0.7）

**实测（我们机器，15s 视频 50 步）**：
- 9 张参考图 → **每步 44s**（异常慢，总 ~36 分钟）
- 之前 10s 单图 → 每步 ~8s，总 ~7 分钟
- 显存 20G→38G 上涨（KV 累积），GPU util 100%（算力被 attention 吞掉）

**参考 token 估算**：768p 图 ≈576 token，1344×768 ≈1008，2048px(max) ≈4096

## 优化方案备选（按收益排序）

| 方案 | 做法 | 预期 |
|---|---|---|
| **减少参考图** | 2-4 张为性价比拐点（front + 1侧视图 + face detail） | 单步 -10~20% |
| **ref_image_size=match** | 缩到生成分辨率（勿用 max，max 单图≈4096 token） | 省显存+时间 |
| **Sage Attention** | vLLM-Omni `TRTLLM_ATTN`+SAGE 量化（Q/K/V fp8）或 ComfyUI Sage 补丁 | ×1.35, SSIM 0.97 |
| **稀疏注意力** | Skip-Softmax Sparse Attention（timestep>0.97, threshold 0.05） | 长序列显著 |
| **Cache-DiT/TeaCache** | 跨步缓存 DiT 残差 | +20-30% |
| **等官方 sparse 权重** | H3 模型卡承诺 future update | 根治二次项 |
| **编码缓存** | 同参考素材复用 encoder 输出 | 摊掉 encode 成本 |

**最坏组合避免**：短视频 + 多参考图（L 小则 ΔL/L 大，相对影响明显）
**参考视频 > 参考图**：双视频 Ref2VA 慢 9 倍（vLLM-Omni 实测），慎用

## 踩坑记录

- **横竖比错误 → 人物压扁**：参考图 2:3 竖版必须配 768×1344 输出
- **多图命名冲突**：多实例并行时独立前缀（gen_parallel）
- **Context IR 与 base 模型参考图是两回事**：IR 吃图写进提示词；base 的 reference_image 直接进模型。可叠加用
- **本地 serve 多图上限 12**（官方 API 9），源码 `MINIMAX_H3_MAX_REFERENCE_COUNT`
- **vLLM-Omni 局限**：serving 路径实际吃图能力受限（多视频/9图支持不全）

## ⚠️ 视频编码档位（2026-08-11 教训）

**首次编码必须选高质量档位，重编码有世代损失，不能补救**。

**实测**：vLLM-Omni 出片默认 **H.264 Constrained Baseline**（profile 66）：
- 不支持 B 帧 / 8x8 变换 / CABAC（用低效的 CAVLC）
- 同等码率下画质最差，768×1344@24fps 用 11.7Mbps 高码率勉强补偿
- **这是 vLLM-Omni 默认值，不是最优档位**

**规则**：
- 出片前**确认编码器 profile 配置**，目标是 H.264 **Main/High profile**（CABAC + B 帧）或 **H.265**——同等码率画质提升 20-30%
- **不要重编码补救**（世代损失），要首次编码就选对

### ✅ 根因 + 修复方案（2026-08-11 已实锤，已打补丁待重启生效）

**根因链**（全部实验验证）：
1. vLLM-Omni 出片走 `entrypoints/openai/serving_video.py` → `video_api_utils._encode_video_bytes` → `media_utils.mux_video_audio_bytes`（PyAV/libx264）
2. `serving_video.py` 默认 `video_codec_options = {"preset": "ultrafast", "threads": "0"}`
3. **x264 的 `ultrafast` preset 强制 Constrained Baseline**——含 `--no-cabac --bframes 0 --no-8x8dct`，且优先级高于任何 profile 设置（命令行 `-profile:v high -preset ultrafast` 实测仍 baseline）
4. PyAV 传 profile 的正确位置：**options 字典且必须在 preset 之后**（`options["profile"]="high"` 追加在 update 之后）；`codec_context.profile` 属性对 libx264 无效（实测）

**已打补丁（vllm_omni_src，editable 生效，重启 serve 后生效）**：
- `serving_video.py`（2 处）：`"preset": "ultrafast"` → `"preset": "veryfast"`
- `media_utils.py`（2 处）：options 末尾追加 `options["profile"] = "high"`
- 验证：veryfast/superfast/fast/medium + profile=high 均输出 **High**（仅 ultrafast 不行）；备份 `media_utils.py.bak`
- 预期收益：CABAC + 8x8dct + B 帧（veryfast 默认 bframes），同 CRF 码率下降 ~20-30%（之前 baseline 11.7Mbps）

**出片后验收**：`ffprobe -show_entries stream=profile` 应显示 High；对比同 seed 旧片码率。

## 关键脚本/文件

- 本地: `h3_ir_multimg.py` / `h3_ir_15s.py`（Context IR 调用）、`ir_prompt_15s.txt`
- 共享盘: `ops/run_ref2va_15s.sh`（多图 15s）、`ops/run_ref2va_multimg.sh`（单图）
- 资产: `uploads/maid/`（9 图 + IR prompt）
- 输出: `uploads/maid/ref2va_15s_9img.mp4（旧路径 uploads/maid/，新片一律 delivery/maid/）`
