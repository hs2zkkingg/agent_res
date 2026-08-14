param(
  [Parameter(Mandatory=$true)][string]$HostName,
  [Parameter(Mandatory=$true)][string]$Task,
  [Parameter(Mandatory=$true)][string]$WorkDir,
  [Parameter(Mandatory=$true)][string]$Command,
  [Parameter(Mandatory=$true)][string]$HealthCmd,
  [int]$TaskTimeout = 3600,
  [int]$InitWait = 8
)

$ErrorActionPreference = "Continue"
$sshOptions = @(
  "-o", "BatchMode=yes",
  "-o", "ConnectTimeout=15",
  "-o", "ServerAliveInterval=30",
  "-o", "ServerAliveCountMax=20",
  "-o", "ConnectionAttempts=1"
)
$stateFile = "$WorkDir/$Task.STATE"

function Invoke-Remote {
  param([string]$RemoteCommand)
  foreach ($attempt in 1..3) {
    $output = & ssh @sshOptions $HostName $RemoteCommand 2>&1
    if ($LASTEXITCODE -eq 0) { return @{ Ok = $true; Output = $output } }
  }
  return @{ Ok = $false; Output = $output }
}

$result = Invoke-Remote "test -f '$stateFile' && cat '$stateFile' || echo NO-STATE"
if (-not $result.Ok) { Write-Error "SSH connection failed"; exit 1 }
$state = ($result.Output | Select-Object -Last 1).Trim()

if ($state -eq "DONE") { Write-Output "SKIP: $Task is DONE"; exit 0 }
if ($state -ne "RUNNING") {
  $launch = "cd '$WorkDir' && WORK_DIR='$WorkDir' setsid nohup bash '$WorkDir/task_wrapper.sh' '$Task' '$TaskTimeout' $Command </dev/null >> '$WorkDir/$Task.launch.log' 2>&1 &"
  $result = Invoke-Remote $launch
  if (-not $result.Ok) { Write-Error "Remote launch failed"; exit 1 }
  Start-Sleep -Seconds $InitWait
}

$waitSeconds = $TaskTimeout + 300
$result = Invoke-Remote "bash '$WorkDir/wait_for.sh' '$stateFile' '$waitSeconds' '$HealthCmd'"
if (-not $result.Ok) {
  $result.Output | Write-Output
  exit 1
}
$result.Output | Write-Output
$last = $result.Output | Select-Object -Last 1
switch -Regex ($last) {
  "COMPLETE: DONE" { exit 0 }
  "COMPLETE: (FAIL|TIMEOUT)" { exit 2 }
  "CRASH" { exit 3 }
  default { exit 1 }
}

