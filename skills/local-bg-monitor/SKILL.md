---
name: local-bg-monitor
description: "本机后台任务快监听纪律：background_process 启动后禁止长 Sleep 死等，必须 10-15 秒一轮快监听（进程存活 + 日志错误标记），错误即停。适用于本机长任务/服务监听。"
---

# 本机后台任务快监听纪律（local-bg-monitor）

## 铁律
- **启动任何 background_process / 长任务后，禁止长 Sleep 死等**（如 Sleep 120/180 秒再查一次）
- 必须立即进入**快监听循环**：10~15 秒一轮，每轮检测「进程存活 + 日志尾部错误标记」，错误即停并读日志尾部
- 背景：曾多次发生"启动后报错 → 死等 2~3 分钟才查 → 白等"，用户明令监听状态

## 快监听循环模板（PowerShell 5.1）
```powershell
$pid2 = <目标pid>; $log = "<日志文件绝对路径>";
for ($i=0; $i -lt 50; $i++) {
  Start-Sleep -Seconds 12
  $alive = Get-Process -Id $pid2 -ErrorAction SilentlyContinue
  $tail = ""
  if (Test-Path $log) { $tail = (Get-Content $log -Tail 3 -Encoding UTF8) -join " | " }
  if (-not $alive) { Write-Output "EXIT_at_$($i*12)s"; Write-Output $tail; break }
  if ($tail -match "Traceback|RuntimeError|ValueError|OutOfMemory|CUDA out|Error:") { Write-Output "ERR_at_$($i*12)s: $tail"; break }
  if ($i -eq 49) { Write-Output "ALIVE_600s: $tail" }
}
```
- 轮数 × 间隔 = 监听上限；到达上限仍存活 → 报告当前进度尾部，重新起一轮
- 训练类任务另加进度检测：日志出现 `Epoch|Step|loss` 说明在正常推进；出现自定义错误标记（如 "WARNING Failed to open"）单独处理

## 关键坑（实测踩坑）
1. **日志必须重定向到文件**：`cmd /c "xxx > run.log 2>&1"`。background_process 的 logs 有时拿不到（进程结束后记录被清），文件永远可查
2. **监听真实 worker 进程，不是 cmd 外壳 pid**：cmd 会先退出而 python 子进程还在跑。用
   `Get-CimInstance Win32_Process -Filter "Name like '%python%'" | Where-Object { $_.CommandLine -match "train.py" }` 检测
3. **stop 后台进程 ≠ 杀干净子进程**：cmd 外壳被杀后 python 子进程残留（占显存/锁资源）。stop 后必须再查 `Win32_Process` 按 CommandLine 匹配杀掉残留，确认 `CLEAN` 再重启
4. 多进程残留会互相干扰（如 pyarrow 文件打开失败、端口占用），报错前先确认没有旧进程活着

## 适用场景
- 本机模型训练/推理/下载等任何耗时命令
- 与远程 ssh 长任务区分：远程走 remote-long-task skill（wait_for.sh + 状态文件），本机走本 skill（快监听循环）
