---
name: sanatsu-voice-clone
description: 锁那（Sanatsu）声线克隆 - GPT-SoVITS 零样本工作流：声源资产、参考音频、训练/推理流程。适用于锁那角色声音克隆任务。
---

# 鎖那（Sanatsu）声线克隆 — GPT-SoVITS 零样本工作流

## 声源资产
- 专辑：《好きなひと。》（鎖那×HoneyWorks，2014-08-17 C86）
- **Secret Track**：第 11 轨 `N:\CD\鎖那\好きなひと\11. 好きなひと。.flac`（508 秒）
  - 0~430s：静音；**430~508s（7:10~8:28）：锁那独白 78 秒**（唯一现成纯人声干声素材）
- 参考音频（3~10 秒硬限制，官方校验）：
  - `C:\GPT-SoVITS\sanatsu_ref_10s_b.wav`（独白最后 10 秒收尾句）★当前使用
  - `C:\GPT-SoVITS\sanatsu_ref_10s.wav`（独白开头 10 秒，备用）
  - `C:\GPT-SoVITS\sanatsu_mono_full.wav`（完整独白，仅存档用，超出参考长度限制）
- prompt_text（与 ref_10s_b 逐字对应）：
  「最後まで聴いてくださった皆様、本当にありがとうございました。それでは、またお会いできる日まで、お元気で。」

## 环境（C:\GPT-SoVITS，conda 环境 GPTSoVits，Python 3.11）
- 部署踩坑（已解决，重装时照此处理）：
  1. RTX 5080 Blackwell 必须 CUDA 12.8 → torch 2.11+cu128（官方 install.ps1 `--Device CU128`）
  2. 模型下载走 **ModelScope 源**（hf-mirror 308 重定向到 huggingface 直连会卡死）；curl 需 `--noproxy "*"`
  3. pyopenjtalk（日语必需）无 win wheel → 装 **VS2022 Build Tools C++** 后源码编译；CMake 必须 ≤3.29（4.x 移除旧语法兼容）
  4. opencc 装 1.4.1 wheel（阿里源有）；pip 源用 `https://mirrors.aliyun.com/pypi/simple/`（清华缺包）
  5. fastapi 必须 pin 0.115.14 + starlette 0.41.3（新版与 gradio 4.44 冲突，WebUI 打不开）
  6. torchcodec 与 torch 2.11 不兼容 → 脚本里 monkey-patch `torchaudio.load` 走 soundfile
  7. `TTS.run()` 返回 **generator**（非 (sr,audio) 元组），必须迭代收集
  8. `parallel_infer=True` 会走批量路径返回结构不同 → 必须 False + `split_bucket=False`
- 启动 WebUI：`call activate GPTSoVits && cd /d C:\GPT-SoVITS && python webui.py zh_CN`（端口 9874，需 NO_PROXY=127.0.0.1,localhost）

## 推理配方（已验证最佳，2026-08-13）
- 模型：**v4**（v2/v2Pro 音色不像，弃用）
- 参数：`sample_steps=64` + `super_sampling=True` + top_k=15 + top_p=1 + temperature=1 + seed=0
- **后处理（必须）**：`ffmpeg -af "deesser=i=0:f=1.0:m=0.5:s=1,highshelf=f=7500:g=-3"`
  （v4 输出高频偏亮、齿音重，de-esser + 7.5kHz 以上 -3dB 后达标；不加后处理有明显齿音）

## 出片
```powershell
# 一体化脚本：合成 + 后处理一步到位，输出 C:\GPT-SoVITS\output\<name>.wav
cmd /c "call C:\Users\hs2zking\miniconda3\Scripts\activate.bat GPTSoVits && cd /d C:\GPT-SoVITS && set PYTHONIOENCODING=utf-8 && python sanatsu_say.py ""<日文文本>"" <输出名>"
```
- 合成+后处理完成，成品直接是最终 wav（已含去齿音处理）
- 中文文本也可（text_lang 改 zh），但锁那声线是日语语感，中日混读用 "auto"

## 后续方向（未做）
- **少样本微调**：CD 共 10 首歌 + 独白，UVR5 分离人声 → 切片 → ASR 标注 → 微调 v2Pro（微调后 v2 音色干净且相似度高，可替代 v4+后处理路线）
- 参考音频可再试独白开头 10 秒（prompt_text 需人工听写逐字匹配，ASR 版有错词风险）
