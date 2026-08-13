---
name: krea2-workflow
description: Krea2 (RedCraft) 图像生成工作流参数规范：步数、采样器、分辨率、负向提示词、深景深技巧、final 回传规范。适用于共享盘 ComfyUI + RedCraft 模型的出图任务。
---

# Krea2 图像生成工作流规范

## 步数（统一 10 步，2026-08-10 定型）

**所有阶段一律 10 步**（抽卡 + final 相同）。

> 用户经验：20~30 步时人物皮肤拟真瑕疵明显增多（过度细节/噪点），**不喜欢**。10 步皮肤干净自然，配合 final 高分辨率 + 2x 超分即可达到理想质量。
>
> 注意：相同 seed 不同 steps 会**显著改变构图**（er_sde 采样器轨迹依赖时间步调度），因此抽卡和 final 必须用相同步数才能保持构图一致。

## 标准工作流

| 阶段 | 分辨率 | steps | 说明 |
|---|---|---|---|
| **抽卡即 final** | **1536×1024（3:2, ~1.5M）** | **10** | 直接最终参数抽卡，选中即定稿 |
| **超分 2x** | RealESRGAN_x2plus 放大 | — | 选中图 1536×1024 → 3072×2048 |

**抽卡即 final**：抽卡直接用最终分辨率+步数，选中图直接超分，**不做二次生成**（seed 无法跨分辨率/步数复现构图，详见下方限制章节）。

## ⚠️ 官方推荐参数（Civitai RedCraft 模型卡，2026-08-10 采纳）

**模型版本**: Krea2-RED-Mix2 赤佬版（17/07/2026）— "No Mosaics. Optimize visual effects"

**Usage**: `ER_SDE/Euler | Simple | CFG=1 | 8-12 Steps`（Mix2 版步数上限放宽到 12）

- **cfg = 1**（我们曾用 1.5，偏高会强化纹理/伪影，可能是皮肤瑕疵来源 → 已改回 1）
- **steps = 8~12**（模型为低步数设计，我们用 10 步，在官方范围内）
- **采样器** er_sde/simple 与官方一致
- **生成分辨率 = 1.5M（1536×1024）**，不要上 2.5M——模型最佳工作区间约 1~1.5M，1920×1280 效果差（结构/细节撑不住），已改回 1.5M
- 2.5M 效果差**不是步数问题**，是分辨率超出模型训练区间

## ⚠️ 关键限制：seed 无法跨参数复现构图（2026-08-10 定论）

**"抽卡选图 → final 重生成保持构图"在原理上不成立**，必须放弃。

**根因**：seed 生成的是**初始噪声 latent**，其形状随分辨率变化。分辨率不同 → 噪声张量尺寸不同 → 内容完全不同 → 采样起点改变 → 构图必然漂移。同理 steps 改变（采样轨迹依赖时间步）也漂移。

**结论**：seed 只在"分辨率 + steps + 参数完全相同"时可复现构图。任何阶段间改变分辨率或步数，构图都会变。

**正确流程：抽卡即 final**（去掉"重生成"环节）：
1. **抽卡直接用最终参数**（1536×1024 + 10 步）——抽卡图就是最终构图
2. 选中图**直接 RealESRGAN 2x 超分**（3072×2048），不再二次生成
3. 备选：img2img refine（denoise 0.3-0.5 提分辨率，构图大体保留但有漂移风险）或纯超分（只锐化不加细节）

## 完整流程（四步，2026-08-10 定型）

```
1. 统一参数生成抽卡（1536×1024 + 10 步, cfg 1）
2. 回传 JPEG 抽卡（q85 打包）→ 用户筛选
3. 选中图超分：RealESRGAN 2x（基于原始 PNG）
4. 回传 final PNG（3072×2048 无损）→ 最终交付
```

**关键**：
- **JPEG 只用于筛选回传**，不是成品；最终交付永远是无损 PNG
- **超分必须基于原始 PNG，不能用 JPEG**——JPEG 有损会放大压缩伪影，超分后更明显。选图后从共享盘取对应 PNG 超分

## final 回传规范（重要）

- **只回传 2x 超分后的原始 PNG**（`.png`，无损，最终交付，3072×2048）
- **中间产物一律删除**：final 原图（1536×1024 PNG）、转的 JPEG、tar 包、远端临时目录
- 本地最终目录只保留 `final_<序号>_2x.png`（原始 PNG，非 JPEG）
- 理由：2x 超分是最终成品，保留无损 PNG；中间物占空间且易混淆

## 超分 2x（final 后处理）

- **模型**：`RealESRGAN_x2plus.pth`（64MB，已上传共享盘 `comfyui/models/upscale_models/`）
- **ComfyUI 节点**：`UpscaleModelLoader`（RealESRGAN_x2plus.pth）+ `ImageUpscaleWithModel` → 再 `SaveImage`
- **流程**：VAEDecode 输出 → 同时接 SaveImage（final 原图）+ ImageUpscaleWithModel → SaveImage（2x 超分图）
- 超分在 GPU 上实时完成，H800 秒级（1536×1024 → 3072×2048）

## 采样参数（已验证 + 官方）

- sampler: `er_sde`
- scheduler: `simple`
- cfg: **1.0**（官方推荐；曾用 1.5 偏高会强化纹理/伪影，可能是皮肤瑕疵来源）
- denoise: 1.0
- 量化模型：RedCraft INT8/INT4/FP8（12.24GB，Krea2 官方实为 12B 参数）

## ⚠️ H800 启动用 --highvram（2026-08-10 实测修正）

**H800 80GB 建议 `--highvram` 启动**（模型全驻留），但**对速度无实锤提升**。

**实测（16 张 × 3 轮稳定值）**：
| 模式 | 16 张 | 单张 | 显存驻留 |
|---|---|---|---|
| dynamic VRAM（默认） | 65s | ~4s | 0.9GB（空闲卸载） |
| --highvram | 65s | ~4s | 20.6GB（常驻） |

**结论**：
- `--highvram` **速度与 dynamic VRAM 相同**（65s/16 张）——RedCraft 单模型负载小，dynamic 的加载开销可忽略
- 价值在**模型常驻**（省动态管理复杂性和潜在抖动），非提速
- 4 张短测曾出现 3s/张是**小样本噪声**，16 张才准
- 启动脚本：`ops/start_comfyui_highvram.sh <端口>`（含 `--highvram`）

**量化反量化开销**：RedCraft INT8/INT4 权重**每次前向都反量化**（`comfy/ops.py` cast_bias_weight，非 warmup 缓存），每步 ~58% CPU 时间花在 copy/fill/clone 搬运。这是模型量化代价。

**加速尝试实测（2026-08-10，16 张 × 3 轮稳定值）**：
| 方案 | 16 张 |
|---|---|
| dynamic VRAM（默认） | 65s |
| --highvram | 65s |
| --enable-triton-backend | 65s（triton backend 已启用，int8_linear 能力在，但无提速） |

**结论**：三个启动方案均无提速（65s 恒定）。RedCraft 的 `comfy_quant` 量化层**未接入 comfy-kitchen 的 triton int8 kernel**（日志仅显示"启用"无实际 kernel 调用），反量化开销无法用启动参数消除。真正加速需**换 FP8 权重**（无逐层反量化，GEMM 直算）或接受现状（~4s/张）。

## 分辨率

- **唯一分辨率（抽卡即 final）**：1536×1024（3:2，1.5M）
- 分辨率需 8 的倍数（VAE latent 对齐）；3:2 + 1.5M → 1536×1024 是标准解
- **不要上 2.5M**（1920×1280）：超出 RedCraft 模型最佳工作区间（约 1~1.5M），效果差
- **不要分阶段换分辨率**（见下方 seed 限制章节）

## 提示词结构（已验证有效）

- 角色外观描述 → 服装细节 → 姿势 → 场景 → 光影 → 摄影风格
- 姿势细节放中段，重点姿势可重复强调
- **深景深**：正向 `wide depth of field / deep focus` + 负向 `shallow depth of field, heavy bokeh, out of focus feet`
- 焦点提示可指定主体（如"camera focuses on the soles of her feet, crisp sharp detail"）
- 负向固定排除：anime, illustration, cartoon, cosplay, fantasy, deformed, extra limbs, bad hands, extra fingers, blurry feet, low quality, watermark

## 女仆场景提示词

> **项目资产**：女仆角色 PROMPT 全文（正向/负向/迭代要点）已迁至 mm_workflow 仓库
> `krea2/prompts/maid_prompt.txt`——skill 只保留总体指导（提示词结构/参数），具体提示词跟项目资产走。


## 多进程并行加速（H800 单卡，2026-08-10 实测修正）

**背景**：H800 80GB 跑 RedCraft 实际只占 ~18GB（dynamic VRAM 推理峰值），**显存大量闲置**。ComfyUI 的 KSampler 处理 batch 是**串行排队**（实测 16/32/64 张耗时线性增长），加大 batch 不能喂满算力。

**方案：单卡多 ComfyUI 实例并行**——每个实例独立加载模型、独立推理，消除排队。

### ⚠️ 实测数据（2026-08-10，同口径：模型驻留后，16 张 1024×1536）

| 方式 | 16 张耗时 | 单张 |
|---|---|---|
| 单实例串行 | **65s**（3 轮稳定） | ~4s |
| 4 实例并行 | **60-61s**（第 2/3 轮稳定） | ~15s/张(被争抢拖慢) |

**GPU 利用率实测（nvidia-smi 采样，2026-08-10）**：
- 单实例串行 16 张期间：**平均 util 95%，峰值 100%，功率 689W（H800 满载 ~700W）**
- **实锤：H800 算力已是瓶颈**，单实例就把 GPU 吃满 95%+

**结论**：
- **瓶颈是单卡算力（GPU util 已 95-100%），不是排队**——多实例并行争抢同一块卡的算力/显存带宽，每张变慢（4s→15s），总吞吐只快 ~8%
- **显存闲置 ≠ 算力闲置**：H800 显存 80GB 但算力（~990 TFLOPS）单张已吃满，两者独立
- 多实例并行的真实价值 = **消除排队**（批量抽卡同时开工），而非算力叠加
- 想真正提速：多卡（4 卡机）或多机，单卡多实例无法突破算力瓶颈

**使用建议**：
- 单张/小批量：单实例串行即可（单张 ~4s 已很快）
- 大批量抽卡（32+ 张）：多实例并行仍可用（略快 + 无排队），但别期待数量级提升
- 想真正提速：多卡（4 卡机）或多机，单卡多实例无法突破算力瓶颈

### 通用脚本（共享盘，已泛化）

**`ops/gen_parallel.sh`**——多实例并行生成（提交 + 等待 + 健康检查一体）：
```bash
# 用法: bash ops/gen_parallel.sh <端口列表> <每实例张数> <基础前缀> [阶段=draft|final] [超时=900]
bash ops/gen_parallel.sh "8188 8189 8190 8191" 8 redcraft_lady draft
```
- **自动独立子前缀**（inst1/inst2/...），避免文件名冲突
- **等待逻辑含三重判定**：各实例队列全空 + 文件计数达标 + 实例 HTTP 健康检查
- **任何实例崩溃立即退出（退出码 3）**，不傻等超时

**`ops/start_comfyui_multi.sh <端口>`**——启动单个实例（参数化端口）：
```bash
bash ops/start_comfyui_multi.sh 8189   # 再起 8189/8190/8191
```

**`ops/wait_gen.sh <glob> <目标数> [超时] [健康检查cmd]`**——通用等待（单实例场景）：
```bash
bash ops/wait_gen.sh 'redcraft_lady_draft_*.png' 32 900
```
- 退出码: 0=完成 / 3=进程崩溃(快速失败) / 1=超时
- **必带健康检查**（默认 pgrep ComfyUI），崩溃 5s 内报错，不傻等

### 关键教训（踩坑）

- **文件名冲突**：多实例用相同前缀会互相覆盖 → 必须独立子前缀
- **等待条件错误 = 傻等 600s**：等待脚本 glob 必须与实际输出名一致；条件到不了就干等超时 → 用"队列全空 + 计数 + 健康检查"三重判定
- **快速失败**：任何实例崩溃立即退出，绝不等到超时
- **对比要同口径**：并行首轮含模型加载，串行要等驻留后对比，否则数字失真

**注意**：ComfyUI batch 不并行（线性耗时），不要依赖 batch 提速；用多实例并行替代（但收益有限，见实测）。

## 批量出图规范

- **逐张提交**（batch=1 + 每次随机 seed），不要用 batch=N（ComfyUI batch 共享 seed，元数据不可区分）
- seed 用 `random.randint(0, 2**31-1)`，记录到 `.seeds.txt` 便于复现
- 详见 `image-batch-generation` skill

## 实操脚本（共享盘）

| 脚本 | 用途 |
|---|---|
| `ops/gen_redcraft_pipeline.py draft N PREFIX` | 抽卡即 final：1920×1280 + 10 步 + 2x 超分，一次出构图+超分 |
| `ops/upscale_png.py <PNG路径...>` | 选中图直接 2x 超分（不重生成，构图 100% 保留）——方案 A 首选 |
| ~~`final_from_seeds.py`~~ | **已废弃**（seed 重生成构图会漂移，勿用） |

## 多细节迭代法

**目标细节模糊时**逐步调整，每次只改一个变量：
1. 强化措辞（deep focus / sharp detail / wide depth of field）
2. 指定对焦主体（"focuses on X, crisp detail"）
3. 调 cfg（1.0→1.5→2.0）
4. 换 scheduler
每次跑 4~8 张快速验证。
> 注意：不要用提高步数来追求细节（皮肤瑕疵会变多），优先高分辨率 + 超分。

## 负面经验（踩坑）

- 手位置与吊带袜（garter belt）冲突时模型会抹掉吊带袜 → 手改抱膝窝（backs of knees）
- "眼珠转但头不动"很违和 → 同时描述头部姿态（head tilted down to the side）+ 眼神（looking down）
- batch 模式种子全同（踩过），必须逐张提交
- **seed 无法跨分辨率/步数复现构图**（分辨率变→噪声形状变，步数变→采样轨迹变）→ 因此废弃"抽卡→final 重生成"，改"抽卡即 final"
- **20-30 步皮肤拟真瑕疵变多**（用户不喜）→ 一律 10 步
