---
name: remote-batch-transfer
description: 远程批量文件传输优化：大批量图片/文件从服务器传回本地时，先远端重编码压缩再打包成单文件（zip），告知共享盘路径走平台通道（丘比特/JupyterLab）下载。适用于潞晨云/AutoDL 等服务器传输 AI 生成图片、视频帧等批量文件。
---

# 远程批量文件传输规范

## 核心原则

**批量小文件（图片等）绝不一一张张 scp**。标准流程：远端重编码压缩 → **zip 打包** → 告知共享盘路径 → **用户走平台通道（丘比特/JupyterLab）下载** → 本地解包。

## 为什么

- scp 对**每个文件**都有独立的 SSH 连接/握手/校验开销，且潞晨云下行 QoS 限速波动大（0.1~6MB/s）
- 几百张图逐个 scp 极慢；即使打包成 tar 单文件，scp 下行仍受 QoS 限速
- **平台通道（丘比特 = JupyterLab）下载不限速**，是唯一可靠的高速下行路径
- 结论：**服务器不做 scp 下行传输，只打包 + 告知路径，用户走丘比特下载**

## 标准流程（图片回传）

### 通用脚本（共享盘，已泛化，勿每次上传）

**`ops/pack_batch.sh`**——通用打包（转 JPEG + zip）：
```bash
# 用法: bash ops/pack_batch.sh <zip名> <源glob> [--jpeg [q]] [--raw]
# 默认 = --jpeg 85
bash ops/pack_batch.sh redcraft_lady32 '/root/highspeedstorage/minmaxh3/comfyui/output/redcraft_lady_draft_*.png' --jpeg 85
bash ops/pack_batch.sh final_2x '/root/highspeedstorage/minmaxh3/comfyui/output/redcraft_*_2x_*.png' --raw   # 无损原图
bash ops/pack_batch.sh h3_videos '/root/highspeedstorage/minmaxh3/comfyui/output/*.mp4' --raw               # 视频
```
- 输出: `<共享盘>/<zip名>.zip`，用 `-0` 快速打包（JPEG/视频已压缩，无额外收益）
- `--jpeg` = 全分辨率 JPEG q85（默认），`--raw` = 原文件直打包

**`ops/wait_gen.sh`**——通用等待（文件数 + ComfyUI 健康检查）：
```bash
# 用法: bash ops/wait_gen.sh <输出glob> <目标数> [超时秒]
bash ops/wait_gen.sh 'redcraft_lady_draft_*.png' 32 900
```
- 退出码: 0=完成 / 3=ComfyUI崩溃 / 1=超时
- 内部带健康检查（pgrep ComfyUI），崩溃立即返回，不傻等

### 1. 远端重编码（图片场景）

AI 生成的 PNG 是高熵纹理，**PNG 已近无损压缩极限，zip 压不动**（实测压缩率 99.4%，无效）。必须转有损格式。

**默认方案：全分辨率 JPEG q85**（不降分辨率，保留可 i2v/精调）。

| 方案 | 相对 PNG | 用途 |
|---|---|---|
| **全分辨率 JPEG q85（默认）** | ~12% | 保留原始分辨率，可继续 i2v/精调 |
| 半分辨率 JPEG q85 | ~4% | 仅特殊情况（纯预览） |

实测：1024×1536 PNG ~2.1MB → JPEG q85 ~260KB；112 张 230MB → 23MB。

```bash
# GPU 机用 venv python 批量转换
V=/root/highspeedstorage/minmaxh3/vllm_omni_venv/bin/python
$V << 'PYEOF'
from PIL import Image
import os, glob
files = glob.glob('/path/out/*.png')
for f in files:
    im = Image.open(f).convert('RGB')
    im.save('/path/jpeg/' + os.path.basename(f).replace('.png','.jpg'), 'JPEG', quality=85)
print(f"converted {len(files)}")
PYEOF
```

### 2. zip 打包（格式固定 zip）

```bash
cd /path/jpeg
zip -0 -j /path/batch.zip *.jpg    # zip 打包 (JPEG 压不动, 用 -0 快速打包, -j 去路径)
```

- **格式固定 zip**（丘比特/JupyterLab 浏览器直接下载+解压，无需 tar）
- JPEG 已是有损压缩，zip 无额外收益，用 `-0`（不压缩）只做打包，速度最快
- 若需无损（最终交付 PNG）：`zip -0 -j /path/batch.zip *.png`

### 3. 告知路径（用户走丘比特下载）

打包完成后**告知用户共享盘 zip 的完整路径**，例如：

```
zip 已打包: /root/highspeedstorage/minmaxh3/delivery/<工作流>/redcraft_lady32.zip
请用丘比特 (JupyterLab) 下载该文件
```

用户通过丘比特/JupyterLab 的网页界面下载（平台通道不限速）。

### 4. 本地解包（用户侧）

```
unzip batch.zip -d <本地目录>
```

## 决策树

- **图片（默认）** → 全分辨率 JPEG q85 + zip 打包，告知路径走丘比特
- **图片需无损/最终交付** → 原 PNG + zip 打包（`zip -0`，不重编码）
- **视频/大文件** → 本身已压缩，直接 zip 打包告知路径
- **必须 scp 时**（无丘比特/平台故障）→ 单文件 zip 传输（`-0`），接受 QoS 限速

## 检查清单

- [ ] 用共享盘通用脚本 `ops/pack_batch.sh <zip名> <glob> [--jpeg|--raw]` 打包（不每次上传脚本）
- [ ] 等待用 `ops/wait_gen.sh <glob> <目标数>`（带健康检查）
- [ ] **告知共享盘完整 zip 路径**，用户走丘比特/JupyterLab 下载
- [ ] 不主动 scp 下行（除非用户明确要求且平台通道不可用）
- [ ] 原图保留在共享盘（如需无损/后续处理）
