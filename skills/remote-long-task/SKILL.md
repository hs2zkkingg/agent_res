---
name: remote-long-task
description: 远程服务器长任务的正确执行方式：单次阻塞等待、状态文件完成检测、任务级超时、幂等重启、避免低效轮询。适用于 SSH 到潞晨云/AutoDL 等 GPU/CPU 服务器跑模型下载、推理、生成等耗时任务。
---

# 远程长任务执行规范

## ⚠️ 元规则：违反后先根治 skill，不单点修补（2026-08-13 用户定案）

**任何 skill 违反发生后的唯一正确动作序列**：

```
1. 分析根因：为什么会违反？(通常是 skill 模板不适配新场景 / 流程缺失 / 机制无触发)
2. 优化 skill：把根因对应的机制补进 skill（扩展模板、加规则、加反例）
3. 最后才修正当前任务：用优化后的 skill 指导修正
```

- ❌ **禁止单点修补**：只修当前问题不动 skill = 同样的违反会再来一次
- ✅ 例（2026-08-13 实例）：等待日志标记时重写自定义 monitor 循环（无健康检查）→ 根因 = wait_for.sh 只支持状态文件等待，缺"日志/条件等待"模板 → 优化 skill 加 `wait_until.sh` 模板 + "等待类型扩展规则" → 之后才用 wait_until.sh 修正当前监控
- 本条适用于所有 skill（AGENTS.md 三门禁同理）

## 核心原则

1. **不要轮询**：禁止 `Start-Sleep 30s; ssh ... tail log` 循环。每次 SSH 有 ~0.7s 握手 + 0.3-1s 命令开销，10 次轮询 = 5 分钟纯等待。
2. **单次阻塞等待**：单次 SSH 在远端等到任务完成再返回。
3. **超时责任在远端**：任务级 `timeout` 由远端脚本自控，本地只做兜底。
4. **幂等 + 状态机**：状态文件决定是否重跑，重连不重复提交。
5. **等待必带健康检查**：等待循环里监控依赖进程/服务活性，崩溃立即返回（退出码 3），绝不傻等超时。

## ⚠️ 等待执行纪律（强制，2026-08-10 补充）

**长任务等待的唯一正确动作序列**（每次照做，不要重新发明）：

```
1. setsid 后台启动任务（日志写文件，结果写文件 + DONE 标记）
2. 短超时(8s) 确认已启动（pgrep 一次，不反复查）
3. 单次 ssh 调 wait_for.sh 等 DONE 标记（长 timeout 阻塞，如 700s）
4. 读结果文件
```

**第 3 步是唯一的等待动作**。违反表现（必须避免）：
- ❌ 本地 `Start-Sleep 240 + ssh 查询` 循环
- ❌ 反复 `pgrep`/数文件确认进度
- ❌ 每次手动写新的等待脚本（用现成 `wait_for.sh`/`wait_gen.sh`）

**根因**：面对新任务时"重新发明等待方式"，而不是套用固定模板。**任何长任务先确认用哪个现成等待脚本，再开始**。

### 等待类型扩展规则（2026-08-13 定案）

**遇到模板不适配的等待类型时，扩展模板而不是重写自定义循环**：
- 状态文件等待 → `wait_for.sh`（现有）
- **日志标记/条件等待** → `wait_until.sh`（见下模板，等日志出现某标记，内置健康检查）
- 重写自定义循环的代价：丢失健康检查、状态不持久化、不可幂等（踩坑实例：2026-08-13 AutoDL 加载监控重写 monitor 循环，无 HEALTH_CMD、无状态文件）

**"观察进度"与"等待完成"分离**：
- 等待完成：只用 wait_for.sh / wait_until.sh（带健康检查）
- 观察进度（想看 mem/vram 等中间状态）：**独立的一次性查询**（不循环），不要写进等待逻辑
- 两者混在一个循环里 = 违反"等结果不轮询"（踩坑实例：monitor_1gpu.sh 每 25s 打 mem/vram 进度 + 等待标记混在一起）

## ⚠️ 阻塞型 API 任务（AI 出片等，2026-08-11 违反教训）

**场景**：vLLM serve 的 `/v1/videos/sync` 是同步阻塞 API——单次出片 10-40 分钟。**本地永远不要同步 curl 阻塞等待**（Bash timeout 内等不完，中途 Ctrl-C 还会留下服务端孤儿任务）。

**正确姿势（后台提交 + 文件完成检测）**：

```
1. setsid nohup bash <出片脚本> </dev/null >/dev/null 2>&1 &   # 后台提交
2. wait_for.sh 检测输出文件出现: bash wait_for.sh <输出路径> <超时s> \
     "pgrep -f 'vllm serve' >/dev/null"   # HEALTH_CMD=serve 存活
3. 完成: ls/ffprobe 验证输出
```

- wait_for.sh 的状态文件参数传**输出文件路径**（文件出现=完成），HEALTH_CMD 传 serve 进程检查（崩溃立即退出码 3）
- **禁止**：`curl /v1/videos/sync` 前台同步跑 + 超长 Bash timeout；超时中止后服务端可能继续生成（孤儿任务白耗 GPU）——重连后先查 serve 日志/GPU 利用率确认
- 出片提交前另见 minimax-h3-ref2va skill 的「出片启动强制序列」（用户确认 → 后台 → 检测）

## 脚本部署纪律（原 script-sync，2026-08-13 合并）

**铁律：本地是唯一权威，远端只做上传和运行**（所有脚本只在本地生成/修改，远端仅 scp 上传 + bash 运行，本地永远最新）。

- **标准流程**：本地 Write（UTF-8）→ 远端 `bash -n` 校验 → scp 上传共享盘 ops/ → 远端 `bash ops/xxx.sh` 极简运行
- **版本一致性（防漂移）**：
  - 任何脚本变更后**立即 scp 同步**——否则远端旧版被再次运行（踩坑实例：本地 VERSION=v4 未同步，25 步更新时 v3 版覆盖回共享盘，出片误用 v3 prompt）
  - 远端应急改动**必须 scp 拉回本地**合并，保持本地权威
  - 出片脚本版本号统一 `VERSION` 变量，升级只改顶部一行
- **运行中禁止覆盖脚本**（bash 混读新旧内容报错）——改脚本前确认后台任务状态
- 备份/git 入库：见 `mm-workflow-backup` skill（本地备份目录 + git mm_workflow 提交）

## 健康检查（泛化机制，所有任务适用）

**场景**：任务依赖的守护进程（ComfyUI / vLLM serve / aria2c 等）中途崩溃时，产物数不再增长，等待脚本若不检查进程会一直傻等到超时。

**机制**：`wait_for.sh` 的 `HEALTH_CMD` 参数——每个轮询周期执行，返回非 0 立即判定 CRASH 退出（退出码 3）。

**HEALTH_CMD 按任务类型选择**：
| 任务 | 健康检查命令 |
|---|---|
| ComfyUI 生成 | `pgrep -f 'comfyui/main.py' >/dev/null` |
| vLLM serve | `pgrep -f 'vllm serve' >/dev/null` |
| 下载 | `pgrep -f 'aria2c' >/dev/null` |
| 端口服务 | `curl -s -o /dev/null http://127.0.0.1:<port>/system_stats` |
| 一般守护 | `pgrep -f '<进程特征>' >/dev/null` |

**事故教训（2026-08-10）**：ComfyUI 写输出目录时 Lustre I/O 错误崩溃，等待脚本只数产物文件卡在 61/64，傻等 15 分钟。加 `pgrep` 健康检查后崩溃即时报错。**任何远程任务的等待脚本都必须带健康检查。**

## 标准模板（本地 `remote-templates/` 目录）

### 0. wait_until.sh（日志标记/条件等待，2026-08-13 新增）

```bash
# 用法: bash wait_until.sh <COND_CMD> [TIMEOUT_SEC] [HEALTH_CMD] [POLL_SEC]
# COND_CMD: 轮询执行的条件命令, 返回0=完成 (如 grep -m1 'AsyncOmniEngine initialized' <log>)
# HEALTH_CMD: 可选, 健康检查, 非0=依赖进程崩溃, 立即退出
# 退出码: 0=完成  3=CRASH(健康检查失败)  1=超时
COND_CMD="${1:?用法: wait_until.sh <COND_CMD> [TIMEOUT_SEC] [HEALTH_CMD]}"
TIMEOUT="${2:-3600}"
HEALTH_CMD="${3:-}"
POLL_SEC="${4:-5}"
t0=$(date +%s)
while true; do
  if eval "$COND_CMD" >/dev/null 2>&1; then
    echo "COMPLETE: 条件满足"
    exit 0
  fi
  if [ -n "$HEALTH_CMD" ] && ! eval "$HEALTH_CMD" >/dev/null 2>&1; then
    echo "CRASH: 健康检查失败: $HEALTH_CMD" >&2
    exit 3
  fi
  now=$(date +%s)
  if [ $((now - t0)) -ge "$TIMEOUT" ]; then
    echo "WAIT-TIMEOUT: ${TIMEOUT}s 条件未满足" >&2
    exit 1
  fi
  sleep "$POLL_SEC"
done
```

- **与 wait_for.sh 分工**：等状态文件 → wait_for.sh；等日志标记/任意条件 → wait_until.sh；**两者都必须带 HEALTH_CMD**
- **等待必须有进度可见性**（2026-08-13 定案）：wait_until 每 60s 打印存活信号（`[wait Ns] 等待中...`）——静默轮询 = 用户干等必然 abort（踩坑实例：venv 14 分钟完成，等待 12 分钟无任何输出，用户差 1 分钟时被迫 abort）
- **⚠️ wait_until 的 COND_CMD 含 shell 语法（`>`/`|`/引号）时，经本地 ssh 内联传参会被本地 shell（PowerShell）解析破坏——一律写 wrapper 脚本文件 scp 上传，ssh 只跑 `bash wrapper.sh`**（2026-08-13 踩坑：内联传 `"grep ... >/dev/null"` 被 PowerShell 当重定向写 C:\dev\null）
- 例：等 serve 就绪 `bash wait_until.sh "grep -m1 'AsyncOmniEngine initialized' /path/vllm.log" 900 "pgrep -f 'vllm serve' >/dev/null"`（此调用必须包在 wrapper .sh 里经 scp 执行，不得 ssh 内联）

### 1. task_wrapper.sh（远端任务封装，唯一入口）

```bash
# 用法: bash task_wrapper.sh <TASK_NAME> <TASK_TIMEOUT_SEC> <REAL_CMD...>
# 状态: <WORK_DIR>/<TASK_NAME>.STATE  (PENDING/RUNNING/DONE/FAIL/TIMEOUT)
# 日志: <WORK_DIR>/<TASK_NAME>.log
# 幂等: DONE->跳过  RUNNING->退出  FAIL/TIMEOUT->重跑
set -u
TASK_NAME="${1:?用法: task_wrapper.sh <TASK_NAME> <TASK_TIMEOUT_SEC> <REAL_CMD...>}"
TASK_TIMEOUT="${2:?需要任务超时秒数}"
shift 2
WORK_DIR="${WORK_DIR:-/root/highspeedstorage/minmaxh3}"
STATE_FILE="$WORK_DIR/$TASK_NAME.STATE"
LOG_FILE="$WORK_DIR/$TASK_NAME.log"
mkdir -p "$WORK_DIR"

if [ -f "$STATE_FILE" ]; then
  prev=$(cat "$STATE_FILE")
  case "$prev" in
    DONE)     echo "SKIP: $TASK_NAME 已 DONE"; exit 0 ;;
    RUNNING)  echo "SKIP: $TASK_NAME 已在运行(RUNNING)"; exit 0 ;;
  esac
fi
echo "RUNNING" > "$STATE_FILE"
echo "=== [$(date '+%F %T')][$(hostname)] $TASK_NAME 启动 ===" >> "$LOG_FILE"
start=$(date +%s)
timeout "$TASK_TIMEOUT" "$@" >> "$LOG_FILE" 2>&1
rc=$?
end=$(date +%s)
echo "=== [$(date '+%F %T')] $TASK_NAME 退出码=$rc 耗时=$((end-start))s ===" >> "$LOG_FILE"
if [ "$rc" -eq 124 ]; then
  echo "TIMEOUT" > "$STATE_FILE"; echo "STATUS: $TASK_NAME -> TIMEOUT" >> "$LOG_FILE"; exit 2
elif [ "$rc" -eq 0 ]; then
  echo "DONE" > "$STATE_FILE";    echo "STATUS: $TASK_NAME -> DONE"    >> "$LOG_FILE"; exit 0
else
  echo "FAIL" > "$STATE_FILE";    echo "STATUS: $TASK_NAME -> FAIL (rc=$rc)" >> "$LOG_FILE"; exit 1
fi
```

### 2. wait_for.sh（远端等待器，单次调用，含可选健康检查）

```bash
# 用法: bash wait_for.sh <STATE_FILE> [TIMEOUT_SEC] [HEALTH_CMD]
# HEALTH_CMD: 可选, 每个轮询周期执行的健康检查命令; 返回非0则判定依赖进程崩溃, 立即退出
# 退出码: 0=DONE  2=FAIL/TIMEOUT  3=CRASH(依赖进程崩溃)  1=等待超时(本地兜底)
STATE_FILE="${1:?用法: wait_for.sh <STATE_FILE> [TIMEOUT_SEC] [HEALTH_CMD]}"
TIMEOUT="${2:-3600}"
HEALTH_CMD="${3:-}"
POLL_SEC=5
if [ ! -f "$STATE_FILE" ]; then echo "ERROR: 状态文件不存在: $STATE_FILE" >&2; exit 1; fi
t0=$(date +%s)
while true; do
  if [ -f "$STATE_FILE" ]; then
    state=$(cat "$STATE_FILE" 2>/dev/null)
    case "$state" in
      DONE)     echo "COMPLETE: DONE";   exit 0 ;;
      FAIL)     echo "COMPLETE: FAIL";   exit 2 ;;
      TIMEOUT)  echo "COMPLETE: TIMEOUT"; exit 2 ;;
    esac
  fi
  # 健康检查: 依赖进程崩溃/服务失活时立即返回, 不傻等超时
  if [ -n "$HEALTH_CMD" ] && ! eval "$HEALTH_CMD" >/dev/null 2>&1; then
    echo "CRASH: 健康检查失败: $HEALTH_CMD" >&2
    exit 3
  fi
  now=$(date +%s)
  if [ $((now - t0)) -ge "$TIMEOUT" ]; then
    echo "WAIT-TIMEOUT: 已等待 ${TIMEOUT}s 状态: $(cat "$STATE_FILE" 2>/dev/null || echo N/A)" >&2
    exit 1
  fi
  sleep "$POLL_SEC"
done
```

**HEALTH_CMD 示例（按任务类型）**：
- ComfyUI 生成任务：`pgrep -f 'comfyui/main.py' >/dev/null`（进程存活）
- 任意服务：`pgrep -f '<进程特征>' >/dev/null`
- 端口活性：`curl -s -o /dev/null http://127.0.0.1:8188/system_stats`
- 下载任务：`pgrep -f 'aria2c' >/dev/null`

> 本次事故：ComfyUI 写输出目录时 Lustre I/O 错误崩溃，等待脚本只数产物文件，卡在 61/64 傻等 15 分钟。加 `pgrep` 健康检查后崩溃即时报错。**等待脚本必须带健康检查**。

### 3. exec_remote.ps1（本地统一入口，三态+崩溃返回）

```powershell
# 用法:
#   powershell -File exec_remote.ps1 -HostName <ssh别名> -Task <任务名> \
#     -WorkDir <远端目录> -Command "远端命令" [-HealthCmd "健康检查命令"] [-TaskTimeout 3600] [-InitWait 10]
# 流程: 幂等检查 -> setsid 启动 -> 单次 wait_for 阻塞(带健康检查) -> 返回
# 退出码: 0=DONE  2=FAIL/TIMEOUT  3=CRASH(依赖进程崩溃)  1=等待超时/异常
param(
  [Parameter(Mandatory=$true)][string]$HostName,
  [Parameter(Mandatory=$true)][string]$Task,
  [string]$WorkDir = "/root/highspeedstorage/minmaxh3",
  [Parameter(Mandatory=$true)][string]$Command,
  [string]$HealthCmd = "pgrep -f 'comfyui/main.py' >/dev/null",
  [int]$TaskTimeout = 3600,
  [int]$InitWait = 10
)
$ErrorActionPreference = "Continue"
$sshOpts = "-o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=20 -o ConnectionAttempts=1"
$stateFile = "$WorkDir/$Task.STATE"
function Invoke-Ssh {
  param([string]$RemoteCmd)
  $out = ""; $ok = $false
  foreach ($i in 1..3) {
    $out = ssh $sshOpts.Split(' ') $HostName $RemoteCmd 2>&1
    if ($LASTEXITCODE -eq 0) { $ok = $true; break }
  }
  return @{ ok = $ok; out = $out }
}
Write-Output "=== exec_remote: $Task @ $HostName ==="
$r = Invoke-Ssh "test -f '$stateFile' && cat '$stateFile' || echo NO-STATE"
if (-not $r.ok) { Write-Output "FAIL: 无法连接"; exit 1 }
$state = ($r.out | Select-Object -Last 1).Trim()
if ($state -eq "DONE")    { Write-Output "SKIP: $Task 已 DONE"; exit 0 }
if ($state -eq "RUNNING") { Write-Output "RUNNING: 已有实例, 直接等待" }
else {
  Write-Output "STATE: $state (准备启动)"
  $launch = "cd '$WorkDir' && WORK_DIR='$WorkDir' setsid nohup bash '$WorkDir/task_wrapper.sh' '$Task' '$TaskTimeout' $Command </dev/null >> '$WorkDir/$Task.launch.log' 2>&1 &"
  $r = Invoke-Ssh $launch
  if (-not $r.ok) { Write-Output "FAIL: 启动失败"; exit 1 }
  Start-Sleep -Seconds $InitWait
}
$waitSec = $TaskTimeout + 300
$waitCmd = "bash '$WorkDir/wait_for.sh' '$stateFile' '$waitSec' '$HealthCmd'"
$t0 = Get-Date
Write-Output "等待任务完成(上限 ${waitSec}s, 健康检查: $HealthCmd)..."
$r = Invoke-Ssh $waitCmd
$el = [math]::Round(((Get-Date) - $t0).TotalSeconds)
if (-not $r.ok) { Write-Output "FAIL: 等待命令异常(检查 $stateFile)"; exit 1 }
$last = ($r.out | Select-Object -Last 1)
Write-Output "RESULT[${el}s]: $last"
Write-Output "日志: $WorkDir/$Task.log"
switch -Regex ($last) {
  "COMPLETE: DONE"    { exit 0 }
  "COMPLETE: FAIL"    { exit 2 }
  "COMPLETE: TIMEOUT" { exit 2 }
  "CRASH"             { exit 3 }
  default             { exit 1 }
}
```

## 使用流程

1. 把 `task_wrapper.sh` + `wait_for.sh` 上传到远端 `$WORK_DIR`
2. 本地调用：`powershell -File exec_remote.ps1 -HostName h800spot -Task download_x -Command "bash dl_x.sh" -TaskTimeout 7200`
3. 按退出码处理：0=成功，2=失败/超时（查 `$Task.log`），1=连接异常（查 STATE 文件）

## 超时层级设计

| 层 | 超时值 | 职责 | 失败动作 |
|---|---|---|---|
| SSH ConnectTimeout | 20s | 防握手挂死 | 重连 ≤3 次 |
| 远端任务 timeout | 任务专属 | **唯一真超时** | 写 STATE=TIMEOUT |
| 本地 wait_for | 任务+300s | 兜底 | 返回退出码 1 |
| Bash 工具 timeout | 任务+600s | 最终兜底 | 查 STATE 确认 |

**正常流程轮不到 Bash 兜底**：远端先超时 -> 状态文件 -> wait_for 读到 -> 返回。

## 模式选择

- **短任务**（<1min）：直接 `ssh host "cmd"` 同步跑，本地 Bash timeout 拉长
- **中长任务**（1min-30min）：exec_remote 三件套
- **超长/用户外出**（>30min）：background_process + exec_remote，完成后写本地日志

### ⚠️ 多阶段长流程拆段等待（2026-08-13 定案，多次违反教训）

**多阶段流程（预热→加载→出片）禁止合并成一个超长 ssh 阻塞**：

1. **每段独立 wait**：每段等待（预热完成/加载完成/出片完成）单独一次 `wait_until.sh`/`wait_for.sh` 短阻塞（**单段 <15 分钟**），段间返回本地汇报进度
2. **禁止单次 ssh 阻塞 >30 分钟**——超过就拆段或转 background_process
3. **用户 abort 等待 ≥2 次 = 信号**：等待方式不对（阻塞过长/体验差），立即切换到分阶段短等待或 background_process，不要第三次用同样的长阻塞
4. **用户 abort 单次等待后：立即做一次性 DONE 检测并返回**（2026-08-13 补充）——abort 不等于任务失败，远端任务（含 DONE 标记逻辑）可能已经/即将完成。正确动作序列：abort → 立即 ssh 一次性查 DONE 标记/日志 → 已完成则返回结果，未完成则转 background_process 或拆段。**禁止 abort 后停住等用户下一句话**（踩坑实例：venv 20:45 已写 DONE，用户 20:44 abort 后我停住没查，用户追问才返回）
4. 踩坑实例（2026-08-13）：预热+加载合并 55 分钟阻塞被用户 abort 3 次；正确做法 = 预热一段（10min）返回汇报 → 加载一段（15min）返回汇报
5. **可变时长任务（pip 装包/下载）默认拆段 10 分钟**（2026-08-13 补充）：这类任务耗时不确定（5-30 分钟），单段阻塞设 30 分钟超时 = 用户干等+必然 abort（踩坑实例：venv 部署 14 分钟完成，但 30 分钟单段阻塞被用户在 12 分钟时 abort）。正确做法：10 分钟一段，每段返回"进行中 + 当前进度"，或直接 background_process 本地后台

## 标记/状态约定

- 状态文件：`<WORK_DIR>/<TASK_NAME>.STATE`，内容 `PENDING/RUNNING/DONE/FAIL/TIMEOUT`
- 日志：`<WORK_DIR>/<TASK_NAME>.log` + `.launch.log`
- 统一放任务目录，不散落

## PowerShell 注意事项

- `$` 在双引号里被插值 -> 远端命令 `\$` 转义，或写 `.sh`/`.ps1` 文件 scp 上传
- 内联 `ssh "python -c '...'"` 多层引号极易崩 -> 一律写脚本文件
- 中文注释在 PowerShell 5.1 可能解析报错 -> 脚本用英文/ASCII

## ⚠️ 远程命令执行铁律（2026-08-10 固化，反复踩坑）

**复杂远程命令一律用"三段式"：本地 Write 写 .sh → scp 上传 → ssh 只执行极简命令。绝不内联。**

```
1. 本地用 Write 工具写远端脚本（bash 语法，无任何转义问题）
2. scp 本地.sh host:/tmp/xxx.sh
3. ssh host "bash /tmp/xxx.sh"   ← 唯一允许的内联命令，极简单参数
```

**判断标准**：
- 内联 ssh 命令**只允许**：`echo`、`ls`、`pgrep -f xxx | wc -l`、`bash /tmp/xxx.sh` 这类无 `$`/`"`/`>` 的简单命令
- 一旦命令里出现 `$变量`、双引号、`>` 重定向、`seq`/`awk`/`for` 循环、嵌套引号 → **必须写 .sh 文件**

**为什么**（PowerShell 5.1 的坑）：
| 场景 | 结果 |
|---|---|
| `ssh "cmd \$x"` | `\$` 转义传给 bash 后语义常错 |
| `ssh "cmd > file"` | PowerShell 把 `>` 当重定向 |
| `ssh "for i in seq"` | `seq` 被本地 PowerShell 解析 |
| 双引号内再嵌 `"` | 引号配对错乱 |
| 中文/特殊字符 | ANSI 编码错乱截断 |

**注意**：本地 `bash` 工具调用**远程命令**时（如 `ssh host "bash /tmp/x.sh"`）也遵循同样规则——远程命令本身写文件，本地只拼极简 ssh 调用。上传辅助命令（scp 传脚本、`bash file.ps1`）写 `.ps1` 文件执行，避免 PowerShell 内联同样问题。

## SSH 认证防挂起（必须）

**所有脚本化 ssh 必须加 `-o BatchMode=yes`**（或 `-o PasswordAuthentication=no`）。

**原因**：非交互环境（脚本/工具）里，ssh 密钥认证失败后会**进入交互式密码提示**（`root@host's password:`），挂起等待输入——而脚本环境没有 TTY，无人能输密码，ssh 一直卡住直到外层超时（实测：没加 BatchMode 卡满 5 分钟；加了 0.2s 快速失败）。

```powershell
# 错误：认证失败会挂起等密码
ssh -o ConnectTimeout=15 host "cmd"

# 正确：认证失败立即返回 rc=255，可快速重试/报错
ssh -o ConnectTimeout=15 -o BatchMode=yes host "cmd"
```

**要点**：
- 交互式手动 ssh 可以不加（人工输密码），但脚本/自动化**必须加**
- BatchMode 配合 `ConnectionAttempts=1` + 本地重试（见重试策略），认证失败秒级暴露而非分钟级挂死
- 适用于 scp 同理（scp 也支持 `-o BatchMode=yes`）

## 重试策略

- SSH 握手失败：重试 3 次，**间隔 0（立即重试）**，总次数固定
- **关键**：`ConnectTimeout` 已经承担"等待网络恢复"的职责（阻塞 N 秒才放弃），失败后再 `Start-Sleep` 是纯浪费——网络在超时窗口内没恢复，多等几秒也不会恢复；恢复则立即重试即可成功
- 唯一例外：`ConnectionAttempts=1`（不做 SSH 层自动重试）时，本地重试间也无需 sleep
- 潞晨云 QoS：下载/推理满载时 SSH 偶发超时属正常，重连即可
- 不要无限重试，不要在轮询循环里重试

## 检查清单

- [ ] 任务启动幂等（STATE 检查）
- [ ] 单次 SSH + 长 timeout，不是循环轮询
- [ ] 状态文件在任务目录
- [ ] **等待脚本带 HEALTH_CMD 健康检查**（进程/服务活性，崩溃立即退出码 3）
- [ ] 退出码明确：0=DONE / 2=FAIL/TIMEOUT / 3=CRASH / 1=等待超时
