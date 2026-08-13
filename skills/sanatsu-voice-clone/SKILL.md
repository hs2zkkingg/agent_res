---
name: sanatsu-voice-clone
description: 锁那（Sanatsu）声线克隆工作流：GPT-SoVITS 零样本出片（当前可用）+ CosyVoice3 SFT 微调（提升上限主力路线）。含声源资产、参考音频、数据管线、Windows 训练踩坑、预提取流程。
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
- 参考音频可再试独白开头 10 秒（prompt_text 需人工听写逐字匹配，ASR 版有错词风险）

---

# CosyVoice3 SFT 微调（上限主力路线，2026-08-13 启动）

## 决策背景
- 零样本天花板：GPT-SoVITS v4 零样本已"很像"但韵律/稳定度受限 → 微调
- 选型：**Fun-CosyVoice3-0.5B-2512**（2025-12 发布，官方评测 SS 75.8 超 CV2 的 72.4；日语原生支持；有开源训练脚本）
- 仅本机 RTX 5080 16GB，龟速可接受；唱歌不考虑，专攻语音

## 环境（C:\CosyVoice，conda 环境 cosyvoice，Python 3.10）
- torch **2.7.1+cu128**（官方 requirements 是 2.3.1/cu121，5080 不支持，必须换）
- 依赖安装踩坑（install_loop.py 逐行装 + 官方源 fallback）：
  1. 阿里源缺老版本包（conformer/diffusers/setuptools 80.9.0 等）→ 阿里失败自动换 `https://pypi.org/simple`
  2. setuptools 83 移除 pkg_resources → 降级 80.9.0；openai-whisper 需 `--no-build-isolation`
  3. deepspeed Linux only → `train.py`/`train_utils.py` 的 import 改 try/except（torch_ddp 引擎不走 deepspeed 代码）
  4. Windows torch 无 NCCL → `--ddp.dist_backend gloo`
  5. **aTrustAgent（深信服）劫持 127.0.0.1 解析**（hosts 里 `127.0.0.1 localhost.sangfor.com.cn`）→ init_process_group 必须用 `file://` init_method + 显式 rank/world_size，TCP rendezvous 必挂
  6. torch 2.7 移除 `group.options` → monitored_barrier 用 `datetime.timedelta(seconds=3600)`
  7. num_workers=0 时 prefetch_factor 必须 None（DataLoader 报错）
  8. parquet 每 epoch 首次打开报 "Failed to open, ex info 34"（Windows pyarrow 瞬时失败）——无害，数据重试后正常读入

## 数据管线（全部本机）
**素材**（说话为主，全部 yt-dlp 下载到 `C:\GPT-SoVITS\dataset\raw\`）：
- FQSXmTzF-bM / D1tJGZ4R1kM：ぱんぱかカフぃR 广播 #43/#44（花譜主持，锁那嘉宾）
- s89QP89NKFM：sleeptight2 单人直播；oDH11wrVA_A：ubique ラジオ对谈
- qQp8h9ijSqw：CLOUD HAIRPIN 直播（单人，贡献 910 段，主数据源）
- 独白 78 秒（secret track，SV 参考来源）

**管线A**（GPTSoVits 环境，`prep_cv_data_a.py`）：ffmpeg 转 16k mono → faster-whisper **large-v3** 转录（vad_filter）→ 过滤（2~18s、avg_logprob≥-0.55、no_speech≤0.35）→ 切段 → `dataset/segments_manifest.json`（2280 段）

**管线B**（cosyvoice 环境）：
- `build_scp.py`：生成 wav.scp/text/utt2spk/instruct
- `extract_embedding.py`（campplus.onnx）→ `filter_by_embedding.py`：独白段 embedding 均值做参考，余弦 **0.55** 阈值 → 保留 1241 段（滤掉花譜/瀬名航）
- `make_parquet_single.py`：**官方 make_parquet_list.py 的 multiprocessing 在 Windows spawn 会炸（全局变量不传递）→ 必须单进程版**
- dev 拆分 62 段（split_dev.py）；dev 必须也有 instruct 列（否则 KeyError: instruct_token）

**预提取（必须，GPU 利用率 3%→37%）**：
- `extract_embedding.py` + `extract_speech_token.py`（speech_tokenizer_v3.onnx，CPU onnxruntime）对 train+dev 各跑一遍 → 生成 utt2embedding.pt / spk2embedding.pt / utt2speech_token.pt
- `rebuild_parquet.py`：把三列写回 parquet（train 排除 dev 的 62 utt）→ 训练时跳过在线提取

## 训练（`C:\CosyVoice\examples\libritts\sanatsu\`）
- conf/cosyvoice3.yaml SFT 修改：`use_spk_embedding: True`、`max_frames_in_batch: 2000→1200`（16GB）、`max_epoch: 200→30`、lr 1e-5 + constantlr（官方 SFT 默认）
- train_llm.cmd 关键点：
  - 环境变量 RANK=0 WORLD_SIZE=1 LOCAL_RANK=0 MASTER_ADDR=127.0.0.1 MASTER_PORT=29501
  - PYTHONPATH=C:\CosyVoice;C:\CosyVoice\third_party\Matcha-TTS
  - 参数：`--train_engine torch_ddp --ddp.dist_backend gloo --num_workers 0 --prefetch 2 --use_amp --qwen_pretrain_path .../CosyVoice-BlankEN --checkpoint .../llm.pt`
  - 日志重定向 `> train_llm.log 2>&1`
- 三个模型顺序训：**llm → flow → hifigan**（各自从对应 .pt checkpoint 开始）
- 速度：预提取后 ~1 min/epoch（1179 段），30 epoch 约 30-40 分钟
- 监听：见 local-bg-monitor skill（快监听循环 + 按 CommandLine 杀残留进程）

## 训练完成后待办
- 平均模型（average_model.py --val_best）
- SFT 推理验证（用独白参考 + 评测句，与 GPT-SoVITS v4 零样本 AB 对比）
- 达标则更新本 skill 的推理配方段（替换/并列 CV3 SFT 出片方式）
