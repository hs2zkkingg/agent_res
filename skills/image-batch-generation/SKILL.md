---
name: image-batch-generation
description: 图像批量生成规范：batch 模式必须用 random seed（每张不同），避免共享 seed 导致批量图雷同。适用于 ComfyUI / diffusers / FLUX / Krea2 等文生图任务的批量出图。
---

# 图像批量生成规范

## 核心原则

**批量出多张"不同"的图 = 逐张独立提交（每张独立 random seed）。ComfyUI 的 batch 参数做不到每张独立随机。**

## 为什么 batch 参数不行

实测（RedCraft/Krea2, ComfyUI 0.30.2）：
- KSampler 一次 batch=32 提交，**所有 32 张 PNG 元数据的 seed 完全相同**（同一个初始 seed）
- 内容差异（36-47 灰度均差）来自 latent 噪声切片，**不是独立随机**
- 单张内容虽不同，但：seed 不可区分、不可单独复现、构图/风格趋向同源

结论：**要"每张独立随机、元数据可区分、可复现"，必须逐张提交**——batch=1 × N 次，每次新 seed。

## 正确做法（逐张独立提交）

```python
import random
import urllib.request, json, time

COMFY = "http://127.0.0.1:8188"
N = 32
seeds = []

for i in range(N):
    seed = random.randint(0, 2**31 - 1)
    seeds.append(seed)
    wf = make_workflow(seed=seed, batch=1)   # EmptyLatentImage batch_size=1
    data = json.dumps({"prompt": wf}).encode()
    req = urllib.request.Request(f"{COMFY}/prompt", data=data,
                                 headers={"Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=30)
    print(f"提交 {i+1}/{N}: seed={seed}", flush=True)
    time.sleep(0.3)   # 避免提交风暴

# 记录 seed 列表便于复现
open("seeds.txt", "w").write("\n".join(map(str, seeds)))
```

要点：
- 每次提交 `EmptyLatentImage.batch_size = 1`，KSampler seed = 独立随机整数
- 循环提交 N 次进队列（ComfyUI 自动排队串行执行）
- 记录全部 seed 到 `seeds.txt`（可复现任一图）
- 同模型连续任务会驻留显存，N 次提交的初始化开销小于 N 倍冷启动
- 提交完用 `remote-long-task` 规范等待队列清空（单次阻塞，不轮询）

## 验证方法

PNG 的 `prompt` 元数据 chunk 里能读到 seed（ComfyUI 自动嵌入）：
- **batch 提交**：N 张图 seed 完全相同 → 不是独立随机（不可复现单张）
- **逐张提交**：每张 seed 唯一 → 正确

```bash
# 提取 PNG 中的 seed
python -c "
import struct, json
f='out.png'; data=open(f,'rb').read(); pos=8
while pos<len(data):
    ln=struct.unpack('>I',data[pos:pos+4])[0]
    ct=data[pos+4:pos+8].decode('latin1')
    if ct=='tEXt':
        kv=data[pos+8:pos+8+ln].split(b'\x00',1)
        if kv[0].decode()=='prompt':
            wf=json.loads(kv[1])
            ks=[n for n in wf.values() if isinstance(n,dict) and n.get('class_type')=='KSampler']
            print('seed =', ks[0]['inputs']['seed'] if ks else 'N/A')
            break
    if ct=='IEND': break
    pos+=12+ln
"
```

正确做法已在上面给出：**逐张提交 + 每张独立 seed + seeds.txt 记录**。

## ComfyUI API 提交（踩坑必看）

**API 的 seed 参数是 `INT` 类型，不接受 `"randomize"` 字符串**——直接传会报 `HTTP Error 400: Bad Request`（`randomize` 只是 UI 控件行为，不是 API 合法值）。

正确做法：在提交脚本里用 `random.randint()` 生成随机整数再写入 workflow：

```python
import random
seed = random.randint(0, 2**31 - 1)
workflow["7"]["inputs"]["seed"] = seed   # KSampler 节点
print(f"seed={seed}")                     # 记录，便于复现
```

- `"randomize"` 仅存在于 ComfyUI 前端 UI（`control_after_generate`），API 层只认整数
- 提交前打印 seed 到日志，需要复现时用同一个整数重提交

## 例外

- 单一图像精调（i2i 迭代、修复重跑）需要固定 seed 复现 → 显式固定
- 对比测试同 seed 不同参数 → 显式固定
- 除此之外一律 randomize

## 检查清单

- [ ] KSampler seed = randomize 或每次随机
- [ ] 日志记录实际 seed（可复现）
- [ ] batch 出图后抽查 2-3 张确认内容不同
- [ ] PNG meta 的 seed 与日志一致（如需复现）
