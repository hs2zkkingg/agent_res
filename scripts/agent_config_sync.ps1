[CmdletBinding()]
param(
    [ValidateSet('audit', 'deploy')]
    [string]$Action = 'audit',

    [switch]$Apply,

    [string]$InstallPath = (Join-Path $env:USERPROFILE '.codex\AGENTS.md'),

    [string]$BackupRoot = (Join-Path $env:USERPROFILE '.codex\backups\agent-config')
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $repoRoot 'agent-config\AGENTS.md'

if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw "Authoritative AGENTS.md is missing: $sourcePath"
}

$sourcePath = [IO.Path]::GetFullPath($sourcePath)
$InstallPath = [IO.Path]::GetFullPath($InstallPath)
$BackupRoot = [IO.Path]::GetFullPath($BackupRoot)

if ([IO.Path]::GetFileName($InstallPath) -ne 'AGENTS.md') {
    throw "InstallPath must target an AGENTS.md file: $InstallPath"
}

$sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
$targetExists = Test-Path -LiteralPath $InstallPath -PathType Leaf
$targetHash = if ($targetExists) {
    (Get-FileHash -LiteralPath $InstallPath -Algorithm SHA256).Hash
} else {
    $null
}

$state = if (-not $targetExists) {
    'MISSING'
} elseif ($sourceHash -eq $targetHash) {
    'MATCH'
} else {
    'DRIFT'
}

Write-Output "STATE=$state"
Write-Output "SOURCE=$sourcePath"
Write-Output "TARGET=$InstallPath"
Write-Output "SOURCE_SHA256=$sourceHash"
if ($targetHash) {
    Write-Output "TARGET_SHA256=$targetHash"
}

if ($Action -eq 'audit') {
    exit 0
}

if (-not $Apply) {
    Write-Output 'PLAN=Deploy authoritative AGENTS.md; back up a differing installed file first.'
    Write-Output 'APPLIED=False'
    exit 0
}

if ($state -eq 'MATCH') {
    Write-Output 'APPLIED=False'
    Write-Output 'RESULT=Already current'
    exit 0
}

$installParent = Split-Path -Parent $InstallPath
New-Item -ItemType Directory -Path $installParent -Force | Out-Null

if ($targetExists) {
    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = Join-Path $BackupRoot "AGENTS.$stamp.$targetHash.md"
    Copy-Item -LiteralPath $InstallPath -Destination $backupPath
    Write-Output "BACKUP=$backupPath"
}

Copy-Item -LiteralPath $sourcePath -Destination $InstallPath -Force
$installedHash = (Get-FileHash -LiteralPath $InstallPath -Algorithm SHA256).Hash
if ($installedHash -ne $sourceHash) {
    throw "Deployment hash verification failed: $installedHash"
}

Write-Output 'APPLIED=True'
Write-Output 'RESULT=MATCH'
Write-Output "INSTALLED_SHA256=$installedHash"
