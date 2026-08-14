$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$script = Join-Path $repoRoot 'scripts\agent_config_sync.ps1'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('agent-config-sync-' + [guid]::NewGuid().ToString('N'))
$codexHome = Join-Path $temporaryRoot '.codex'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

try {
    & $script deploy -CodexHome $codexHome -Apply | Out-Null
    $installed = Join-Path $codexHome 'AGENTS.md'
    Assert-True (Test-Path -LiteralPath $installed -PathType Leaf) 'Initial deploy did not create AGENTS.md'
    & $script audit -CodexHome $codexHome -Strict | Out-Null

    [IO.File]::WriteAllText($installed, 'test drift', (New-Object Text.UTF8Encoding($false)))
    & $script deploy -CodexHome $codexHome -Apply | Out-Null
    $backupRoot = Join-Path $codexHome 'backups\agent-config'
    $backups = @(Get-ChildItem -LiteralPath $backupRoot -File)
    Assert-True ($backups.Count -eq 1) 'Drift replacement did not create exactly one backup'

    $beforeRestore = (Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash
    & $script restore -CodexHome $codexHome -BackupPath $backups[0].FullName | Out-Null
    Assert-True (((Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash) -eq $beforeRestore) 'Restore dry-run changed the target'

    & $script restore -CodexHome $codexHome -BackupPath $backups[0].FullName -Apply | Out-Null
    Assert-True (((Get-Content -LiteralPath $installed -Raw -Encoding UTF8)) -eq 'test drift') 'Restore did not install the selected backup'

    & $script deploy -CodexHome $codexHome -Apply | Out-Null
    $backups = @(Get-ChildItem -LiteralPath $backupRoot -File)
    Assert-True ($backups.Count -ge 3) 'Expected restore and deploy recovery backups'

    & $script prune-backups -CodexHome $codexHome -Keep 1 | Out-Null
    Assert-True (@(Get-ChildItem -LiteralPath $backupRoot -File).Count -eq $backups.Count) 'Prune dry-run removed backups'
    & $script prune-backups -CodexHome $codexHome -Keep 1 -Apply | Out-Null
    Assert-True (@(Get-ChildItem -LiteralPath $backupRoot -File).Count -eq 1) 'Prune apply did not keep exactly one backup'

    [IO.File]::WriteAllText($installed, 'strict drift', (New-Object Text.UTF8Encoding($false)))
    $previousErrorPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script audit -CodexHome $codexHome -Strict 2>$null | Out-Null
    $strictExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorPreference
    Assert-True ($strictExitCode -ne 0) 'Strict audit did not return a nonzero exit code for drift'

    Write-Output 'PASS agent_config_sync'
} finally {
    if (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
