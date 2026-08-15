[CmdletBinding()]
param(
    [string]$RegistryPath,
    [string]$AiRoot = 'D:\AI',
    [string]$CodexProjectsRoot,
    [string]$PythonPath = $env:CODEX_PYTHON,
    [switch]$ValidateOnly,
    [switch]$AllowDirtyAuthoritative,
    [switch]$SkipManagedHealth,
    [switch]$SkipEnvironmentCheck,
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $RegistryPath) {
    $RegistryPath = Join-Path $repoRoot 'config\ai-projects.json'
}
if (-not $CodexProjectsRoot) {
    $CodexProjectsRoot = Split-Path -Parent $repoRoot
}

$tokens = @{
    AI_ROOT = [IO.Path]::GetFullPath($AiRoot).TrimEnd('\')
    CODEX_PROJECTS_ROOT = [IO.Path]::GetFullPath($CodexProjectsRoot).TrimEnd('\')
    USERPROFILE = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')
}

function Expand-InventoryPath {
    param([Parameter(Mandatory)][string]$Value, [switch]$AllowMissingEnvironment)
    $expanded = $Value
    foreach ($name in $script:tokens.Keys) {
        $expanded = $expanded.Replace(('${' + $name + '}'), $script:tokens[$name])
    }
    $matches = [regex]::Matches($expanded, '\$\{([A-Z0-9_]+)\}')
    foreach ($match in $matches) {
        $name = $match.Groups[1].Value
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if (-not $value) { $value = [Environment]::GetEnvironmentVariable($name, 'User') }
        if (-not $value) {
            if ($AllowMissingEnvironment) { return $null }
            throw "Environment variable is not set: $name"
        }
        $expanded = $expanded.Replace($match.Value, $value)
    }
    return [IO.Path]::GetFullPath($expanded)
}

function Add-Warning {
    param([string]$Message)
    $script:warnings.Add($Message)
    Write-Output "WARN $Message"
}

function Add-Failure {
    param([string]$Message)
    $script:failures.Add($Message)
    Write-Output "FAIL $Message"
}

function Invoke-GitText {
    param([string]$Root, [string[]]$Arguments)
    $output = @(& git -c "safe.directory=$Root" -C $Root @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Git failed in ${Root}: git $($Arguments -join ' ')"
    }
    return ($output -join "`n").Trim()
}

if (-not (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) {
    throw "Missing AI project registry: $RegistryPath"
}
$registry = Get-Content -LiteralPath $RegistryPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($registry.schema_version -ne 1) { throw 'Unsupported AI project registry schema' }
$projects = @($registry.projects)
if (-not $projects.Count) { throw 'AI project registry contains no projects' }
$ids = @($projects | ForEach-Object { $_.id })
if (@($ids | Where-Object { -not $_ }).Count) { throw 'Every project requires an id' }
if (@($ids | Sort-Object -Unique).Count -ne $ids.Count) { throw 'Project ids must be unique' }
foreach ($project in $projects) {
    if ($project.kind -notin @('authoritative', 'third-party')) {
        throw "Unsupported project kind for $($project.id): $($project.kind)"
    }
    if (-not $project.root) { throw "Project root is missing: $($project.id)" }
}
Write-Output "REGISTRY=PASS projects=$($projects.Count)"
if ($ValidateOnly) {
    Write-Output 'HEALTH=PASS'
    return
}

$script:warnings = [Collections.Generic.List[string]]::new()
$script:failures = [Collections.Generic.List[string]]::new()

foreach ($project in $projects) {
    $root = Expand-InventoryPath $project.root
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        Add-Failure "project=$($project.id) missing_root=$root"
        continue
    }
    if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) {
        Add-Failure "project=$($project.id) not_git_repository=$root"
        continue
    }

    $expectedRemote = $project.remote
    $expectedBranch = $project.branch
    $expectedHead = $null
    if ($project.dependency_lock) {
        $lockPath = Expand-InventoryPath $project.dependency_lock.path
        if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
            Add-Failure "project=$($project.id) missing_dependency_lock=$lockPath"
            continue
        }
        $lock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $entry = @($lock.repositories | Where-Object { $_.id -eq $project.dependency_lock.id })
        if ($entry.Count -ne 1) {
            Add-Failure "project=$($project.id) dependency_lock_entry_count=$($entry.Count)"
            continue
        }
        $expectedRemote = $entry[0].remote
        $expectedBranch = $entry[0].branch
        $expectedHead = $entry[0].commit
    }

    $actualRemote = Invoke-GitText $root @('remote', 'get-url', 'origin')
    $actualBranch = Invoke-GitText $root @('branch', '--show-current')
    $actualHead = Invoke-GitText $root @('rev-parse', 'HEAD')
    if ($expectedRemote -and $actualRemote -ne $expectedRemote) {
        Add-Failure "project=$($project.id) remote_mismatch"
    }
    if ($expectedBranch -and $actualBranch -ne $expectedBranch) {
        Add-Failure "project=$($project.id) branch=$actualBranch expected=$expectedBranch"
    }
    if ($expectedHead -and $actualHead -ne $expectedHead) {
        Add-Failure "project=$($project.id) head=$actualHead expected=$expectedHead"
    }

    $status = @((Invoke-GitText $root @('status', '--porcelain=v1')) -split "`n" |
        Where-Object { $_ })
    if ($project.kind -eq 'authoritative') {
        if ($project.require_clean -and $status.Count -and -not $AllowDirtyAuthoritative) {
            Add-Failure "project=$($project.id) dirty_files=$($status.Count)"
        } elseif ($status.Count) {
            Add-Warning "project=$($project.id) dirty_files=$($status.Count) allowed_for_precommit=true"
        }
        if ($project.require_remote_match) {
            $tracking = Invoke-GitText $root @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')
            $remoteHead = Invoke-GitText $root @('rev-parse', $tracking)
            if ($actualHead -ne $remoteHead) {
                Add-Failure "project=$($project.id) local_remote_mismatch"
            }
        }
    } else {
        $tracked = @((Invoke-GitText $root @('status', '--porcelain=v1', '--untracked-files=no')) -split "`n" |
            Where-Object { $_ })
        if ($entry -and $tracked.Count -ne $entry[0].tracked_worktree_changes) {
            Add-Failure "project=$($project.id) tracked_changes=$($tracked.Count) expected=$($entry[0].tracked_worktree_changes)"
        }
        if ($entry -and $entry[0].patch) {
            $lockRepo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $lockPath))
            $patchPath = Join-Path $lockRepo $entry[0].patch
            if (-not (Test-Path -LiteralPath $patchPath -PathType Leaf)) {
                Add-Failure "project=$($project.id) missing_patch=$patchPath"
            } else {
                & git -c "safe.directory=$root" -C $root apply --reverse --check $patchPath
                if ($LASTEXITCODE -ne 0) {
                    Add-Failure "project=$($project.id) reverse_patch_check"
                } else {
                    Write-Output "PASS project=$($project.id) reverse_patch_check"
                }
            }
        }
        Write-Output "PASS project=$($project.id) third_party_head=$actualHead tracked_changes=$($tracked.Count)"
    }
    if ($project.kind -eq 'authoritative' -and -not $status.Count) {
        Write-Output "PASS project=$($project.id) clean_remote_match"
    }

    if ($project.dependency_inventory) {
        $inventoryPath = Expand-InventoryPath $project.dependency_inventory
        if (-not (Test-Path -LiteralPath $inventoryPath -PathType Leaf)) {
            Add-Failure "project=$($project.id) missing_dependency_inventory=$inventoryPath"
        } else {
            $inventory = Get-Content -LiteralPath $inventoryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $bizhawk = $inventory.dependencies.bizhawk
            $archive = Join-Path $root $bizhawk.archive
            if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
                Add-Failure "project=$($project.id) missing_bizhawk_archive=$archive"
            } elseif ((Get-Item -LiteralPath $archive).Length -ne $bizhawk.bytes -or
                (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $bizhawk.sha256) {
                Add-Failure "project=$($project.id) bizhawk_archive_mismatch"
            } else {
                Write-Output "PASS project=$($project.id) bizhawk_archive"
            }

            $research = $inventory.dependencies.fire_emblem_7_j_research
            $researchRoot = Join-Path $root $research.path
            if (-not (Test-Path -LiteralPath (Join-Path $researchRoot '.git'))) {
                Add-Failure "project=$($project.id) missing_research_repository=$researchRoot"
            } else {
                $researchHead = Invoke-GitText $researchRoot @('rev-parse', 'HEAD')
                $researchRemote = Invoke-GitText $researchRoot @('remote', 'get-url', 'origin')
                if ($researchHead -ne $research.commit -or $researchRemote -ne $research.remote) {
                    Add-Failure "project=$($project.id) research_dependency_mismatch"
                } else {
                    Write-Output "PASS project=$($project.id) research_dependency"
                }
            }
        }
    }
}

foreach ($asset in @($registry.external_assets)) {
    $path = Expand-InventoryPath $asset.path -AllowMissingEnvironment
    if (-not $path) {
        if ($asset.required) { Add-Failure "asset=$($asset.id) unresolved_environment" }
        else { Add-Warning "asset=$($asset.id) unresolved_environment" }
        continue
    }
    if (-not (Test-Path -LiteralPath $path)) {
        if ($asset.required) { Add-Failure "asset=$($asset.id) missing=$path" }
        else { Add-Warning "asset=$($asset.id) missing=$path" }
    } else {
        Write-Output "PASS asset=$($asset.id)"
    }
}

if (-not $SkipManagedHealth) {
    try {
        & (Join-Path $PSScriptRoot 'verify_all.ps1')
    } catch {
        Add-Failure 'managed_repository_health'
    }
}

if (-not $SkipEnvironmentCheck) {
    if (-not $PythonPath) {
        $fallback = Join-Path $env:USERPROFILE 'miniconda3\envs\gpt-sovits-v4\python.exe'
        if (Test-Path -LiteralPath $fallback -PathType Leaf) { $PythonPath = $fallback }
    }
    $lockPath = Expand-InventoryPath $registry.environment_lock
    $validator = Join-Path $tokens['CODEX_PROJECTS_ROOT'] 'mm_workflow\tools\verify_environment_locks.py'
    if (-not $PythonPath -or -not (Test-Path -LiteralPath $PythonPath -PathType Leaf)) {
        Add-Failure 'environment_validator_python_missing'
    } elseif (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
        Add-Failure "environment_validator_missing=$validator"
    } else {
        $environmentOutput = @(& $PythonPath -B $validator --lock $lockPath)
        $environmentExit = $LASTEXITCODE
        $environmentOutput | Write-Output
        $environmentWarnings = @($environmentOutput | Where-Object { $_ -match '^WARN ' })
        if ($environmentWarnings.Count) {
            Add-Warning "environment_launcher_warnings=$($environmentWarnings.Count)"
        }
        if ($environmentExit -ne 0) { Add-Failure 'environment_lock_validation' }
    }
}

if ($failures.Count) {
    Write-Output "HEALTH=FAIL failures=$($failures.Count) warnings=$($warnings.Count)"
    throw 'AI workspace health check failed'
}
if ($Strict -and $warnings.Count) {
    Write-Output "HEALTH=FAIL failures=0 warnings=$($warnings.Count) strict=true"
    throw 'AI workspace health check failed in strict mode'
}
$state = if ($warnings.Count) { 'WARN' } else { 'PASS' }
Write-Output "HEALTH=$state failures=0 warnings=$($warnings.Count)"
