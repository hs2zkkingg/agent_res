[CmdletBinding()]
param(
    [string[]]$Manifest,

    [string]$PythonPath = $env:CODEX_PYTHON,

    [string]$CodexHome = $(if ($env:CODEX_HOME) {
        $env:CODEX_HOME
    } else {
        Join-Path $env:USERPROFILE '.codex'
    }),

    [switch]$RunTests
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$configScript = Join-Path $PSScriptRoot 'agent_config_sync.ps1'
$syncScript = Join-Path $repoRoot 'skills\codex-skill-sync\scripts\skill_sync.py'
$installRoot = Join-Path ([IO.Path]::GetFullPath($CodexHome)) 'skills'

if (-not $Manifest) {
    $Manifest = @(Join-Path $repoRoot 'skills\manifest.json')
    $projectManifest = Join-Path (Split-Path -Parent $repoRoot) 'mm_workflow\skills\manifest.json'
    if (Test-Path -LiteralPath $projectManifest -PathType Leaf) {
        $Manifest += $projectManifest
    }
}

if (-not $PythonPath) {
    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
    if ($pythonCommand) {
        $PythonPath = $pythonCommand.Source
    } else {
        $bundledPython = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
        if (Test-Path -LiteralPath $bundledPython -PathType Leaf) {
            $PythonPath = $bundledPython
        }
    }
}
if (-not $PythonPath -or -not (Test-Path -LiteralPath $PythonPath -PathType Leaf)) {
    throw 'Python was not found. Set CODEX_PYTHON or pass -PythonPath.'
}

foreach ($manifestPath in $Manifest) {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Manifest is missing: $manifestPath"
    }
    Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null
}
Write-Output 'PASS manifests-json'

& $configScript audit -CodexHome $CodexHome -Strict | Out-Null
Write-Output 'PASS agent-config'

$refreshArguments = @($syncScript, 'refresh', '--strict')
$auditArguments = @($syncScript, 'audit', '--strict', '--install-root', $installRoot)
foreach ($manifestPath in $Manifest) {
    $refreshArguments += @('--manifest', $manifestPath)
    $auditArguments += @('--manifest', $manifestPath)
}

& $PythonPath @refreshArguments | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Skill manifest refresh audit failed with exit code $LASTEXITCODE"
}
Write-Output 'PASS skill-manifest-hashes'

& $PythonPath @auditArguments | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Skill source/install audit failed with exit code $LASTEXITCODE"
}
Write-Output 'PASS skill-install-state'

$repositories = @($repoRoot)
foreach ($manifestPath in $Manifest) {
    $repositories += (Split-Path -Parent (Split-Path -Parent ([IO.Path]::GetFullPath($manifestPath))))
}
$repositories = @($repositories | Sort-Object -Unique)
$textExtensions = @('.bat', '.cmd', '.json', '.jsonc', '.md', '.ps1', '.py', '.sh', '.toml', '.txt', '.yaml', '.yml')
$secretPatterns = @(
    ('s' + 'k-[A-Za-z0-9_-]{16,}'),
    ('Bearer' + '\s+[A-Za-z0-9._-]{16,}'),
    ('-----BEGIN ' + '[A-Z ]*PRIVATE KEY-----')
)

foreach ($repository in $repositories) {
    git -c safe.directory=$repository -C $repository diff --check
    if ($LASTEXITCODE -ne 0) {
        throw "git diff --check failed: $repository"
    }

    $changed = @()
    $changed += git -c safe.directory=$repository -C $repository diff HEAD --name-only
    $changed += git -c safe.directory=$repository -C $repository ls-files --others --exclude-standard
    $changed = @($changed | Where-Object { $_ } | Sort-Object -Unique)

    $largeFiles = @()
    $utf8Errors = @()
    $secretFiles = @()
    foreach ($relative in $changed) {
        $path = Join-Path $repository $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }
        if ((Get-Item -LiteralPath $path).Length -gt 1MB) {
            $largeFiles += $relative
        }
        if ([IO.Path]::GetExtension($path).ToLowerInvariant() -notin $textExtensions) {
            continue
        }
        try {
            $bytes = [IO.File]::ReadAllBytes($path)
            $utf8 = New-Object Text.UTF8Encoding($false, $true)
            $content = $utf8.GetString($bytes)
        } catch {
            $utf8Errors += $relative
            continue
        }
        if ($content -match ($secretPatterns -join '|')) {
            $secretFiles += $relative
        }
    }

    if ($largeFiles.Count -or $utf8Errors.Count -or $secretFiles.Count) {
        Write-Output "REPOSITORY=$repository"
        $largeFiles | ForEach-Object { Write-Output "LARGE_FILE=$_" }
        $utf8Errors | ForEach-Object { Write-Output "UTF8_ERROR=$_" }
        $secretFiles | ForEach-Object { Write-Output "SECRET_PATTERN_FILE=$_" }
        throw "Changed-file validation failed: $repository"
    }
    Write-Output "PASS repository=$repository changed=$($changed.Count)"
}

if ($RunTests) {
    & $PythonPath -B -m unittest discover -s (Join-Path $repoRoot 'tests') -p 'test_skill_sync.py'
    if ($LASTEXITCODE -ne 0) {
        throw 'Skill sync tests failed'
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'tests\test_agent_config_sync.ps1')
    if ($LASTEXITCODE -ne 0) {
        throw 'Agent config tests failed'
    }
    Write-Output 'PASS tests'
}

Write-Output 'HEALTH=PASS'
