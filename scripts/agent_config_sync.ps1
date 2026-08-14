[CmdletBinding()]
param(
    [ValidateSet('audit', 'deploy', 'list-backups', 'restore', 'prune-backups')]
    [string]$Action = 'audit',

    [switch]$Apply,

    [switch]$Strict,

    [string]$CodexHome = $(if ($env:CODEX_HOME) {
        $env:CODEX_HOME
    } else {
        Join-Path $env:USERPROFILE '.codex'
    }),

    [string]$BackupPath,

    [ValidateRange(1, 1000)]
    [int]$Keep = 10
)

$ErrorActionPreference = 'Stop'

function Test-PathWithin {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Parent
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $resolvedParent = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    return $resolvedPath.Equals($resolvedParent, [StringComparison]::OrdinalIgnoreCase) -or
        $resolvedPath.StartsWith($resolvedParent + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Install-Atomically {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Target
    )

    $targetParent = Split-Path -Parent $Target
    New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
    $temporary = Join-Path $targetParent ('.AGENTS.{0}.{1}.tmp' -f $PID, [guid]::NewGuid().ToString('N'))
    $replaceBackup = Join-Path $targetParent ('.AGENTS.{0}.{1}.replace-backup' -f $PID, [guid]::NewGuid().ToString('N'))
    try {
        Copy-Item -LiteralPath $Source -Destination $temporary
        $sourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
        $temporaryHash = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash
        if ($temporaryHash -ne $sourceHash) {
            throw "Temporary copy hash verification failed: $temporaryHash"
        }

        if (Test-Path -LiteralPath $Target -PathType Leaf) {
            [IO.File]::Replace($temporary, $Target, $replaceBackup)
            Remove-Item -LiteralPath $replaceBackup -Force
        } else {
            [IO.File]::Move($temporary, $Target)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
        if (Test-Path -LiteralPath $replaceBackup -PathType Leaf) {
            Remove-Item -LiteralPath $replaceBackup -Force
        }
    }
}

function Backup-InstalledConfig {
    param(
        [Parameter(Mandatory = $true)][string]$Installed,
        [Parameter(Mandatory = $true)][string]$DestinationRoot
    )

    $installedHash = (Get-FileHash -LiteralPath $Installed -Algorithm SHA256).Hash
    New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
    $backup = Join-Path $DestinationRoot "AGENTS.$stamp.$installedHash.md"
    if (Test-Path -LiteralPath $backup) {
        throw "Backup destination already exists: $backup"
    }
    Copy-Item -LiteralPath $Installed -Destination $backup
    if ((Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash -ne $installedHash) {
        throw "Backup hash verification failed: $backup"
    }
    Write-Output "BACKUP=$backup"
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$sourcePath = [IO.Path]::GetFullPath((Join-Path $repoRoot 'agent-config\AGENTS.md'))
$CodexHome = [IO.Path]::GetFullPath($CodexHome).TrimEnd('\')
$profileRoot = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')
$driveRoot = [IO.Path]::GetPathRoot($CodexHome).TrimEnd('\')

if ($CodexHome.Equals($profileRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $CodexHome.Equals($driveRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe CodexHome: $CodexHome"
}

$installPath = Join-Path $CodexHome 'AGENTS.md'
$backupRoot = Join-Path $CodexHome 'backups\agent-config'

if (-not (Test-PathWithin -Path $installPath -Parent $CodexHome)) {
    throw "Install path escapes CodexHome: $installPath"
}
if (-not (Test-PathWithin -Path $backupRoot -Parent $CodexHome)) {
    throw "Backup root escapes CodexHome: $backupRoot"
}

if ($Action -eq 'list-backups') {
    $backups = if (Test-Path -LiteralPath $backupRoot -PathType Container) {
        @(Get-ChildItem -LiteralPath $backupRoot -File -Filter 'AGENTS.*.md' |
            Sort-Object LastWriteTimeUtc -Descending)
    } else {
        @()
    }
    Write-Output "BACKUPS=$($backups.Count)"
    foreach ($backup in $backups) {
        Write-Output "BACKUP=$($backup.FullName)"
    }
    return
}

if ($Action -eq 'prune-backups') {
    $backups = if (Test-Path -LiteralPath $backupRoot -PathType Container) {
        @(Get-ChildItem -LiteralPath $backupRoot -File -Filter 'AGENTS.*.md' |
            Sort-Object LastWriteTimeUtc -Descending)
    } else {
        @()
    }
    $remove = @($backups | Select-Object -Skip $Keep)
    Write-Output "KEEP=$Keep"
    Write-Output "REMOVE_COUNT=$($remove.Count)"
    foreach ($backup in $remove) {
        $prefix = if ($Apply) { 'REMOVE' } else { 'REMOVE_DRY_RUN' }
        Write-Output "$prefix=$($backup.FullName)"
        if ($Apply) {
            Remove-Item -LiteralPath $backup.FullName -Force
        }
    }
    Write-Output "APPLIED=$([bool]$Apply)"
    return
}

if ($Action -eq 'restore') {
    if (-not $BackupPath) {
        throw 'restore requires -BackupPath'
    }
    $BackupPath = [IO.Path]::GetFullPath($BackupPath)
    if (-not (Test-PathWithin -Path $BackupPath -Parent $backupRoot)) {
        throw "BackupPath must stay inside $backupRoot"
    }
    if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
        throw "Backup file is missing: $BackupPath"
    }

    Write-Output "RESTORE_SOURCE=$BackupPath"
    Write-Output "TARGET=$installPath"
    if (-not $Apply) {
        Write-Output 'APPLIED=False'
        return
    }

    if (Test-Path -LiteralPath $installPath -PathType Leaf) {
        Backup-InstalledConfig -Installed $installPath -DestinationRoot $backupRoot
    }
    Install-Atomically -Source $BackupPath -Target $installPath
    $restoredHash = (Get-FileHash -LiteralPath $installPath -Algorithm SHA256).Hash
    $backupHash = (Get-FileHash -LiteralPath $BackupPath -Algorithm SHA256).Hash
    if ($restoredHash -ne $backupHash) {
        throw "Restore hash verification failed: $restoredHash"
    }
    Write-Output 'APPLIED=True'
    Write-Output "RESTORED_SHA256=$restoredHash"
    return
}

if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw "Authoritative AGENTS.md is missing: $sourcePath"
}

$sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
$targetExists = Test-Path -LiteralPath $installPath -PathType Leaf
$targetHash = if ($targetExists) {
    (Get-FileHash -LiteralPath $installPath -Algorithm SHA256).Hash
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
Write-Output "TARGET=$installPath"
Write-Output "SOURCE_SHA256=$sourceHash"
if ($targetHash) {
    Write-Output "TARGET_SHA256=$targetHash"
}

if ($Action -eq 'audit') {
    if ($Strict -and $state -ne 'MATCH') {
        throw "Strict audit requires MATCH, found $state"
    }
    return
}

if (-not $Apply) {
    Write-Output 'PLAN=Deploy authoritative AGENTS.md; back up a differing installed file first.'
    Write-Output 'APPLIED=False'
    return
}

if ($state -eq 'MATCH') {
    Write-Output 'APPLIED=False'
    Write-Output 'RESULT=Already current'
    return
}

if ($targetExists) {
    Backup-InstalledConfig -Installed $installPath -DestinationRoot $backupRoot
}
Install-Atomically -Source $sourcePath -Target $installPath
$installedHash = (Get-FileHash -LiteralPath $installPath -Algorithm SHA256).Hash
if ($installedHash -ne $sourceHash) {
    throw "Deployment hash verification failed: $installedHash"
}

Write-Output 'APPLIED=True'
Write-Output 'RESULT=MATCH'
Write-Output "INSTALLED_SHA256=$installedHash"
