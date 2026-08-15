[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PlanPath,

    [string]$AiRoot = 'D:\AI',

    [string]$UserRoot = $env:USERPROFILE,

    [string[]]$AllowedSourceRoot = @($env:USERPROFILE),

    [switch]$Apply
)

$ErrorActionPreference = 'Stop'

function Resolve-FullPath {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        throw "Path is not absolute: $Path"
    }
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Assert-PathBelowRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Root,
        [Parameter(Mandatory)][string]$Role
    )

    $full = Resolve-FullPath $Path
    foreach ($candidate in $Root) {
        $rootFull = Resolve-FullPath $candidate
        if ($full.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return $full
        }
    }
    throw "$Role path is outside its allowed roots: $full"
}

function Expand-PlanPath {
    param([Parameter(Mandatory)][string]$Path)
    return $Path.Replace('${USER_ROOT}', $script:ResolvedUserRoot).
        Replace('${AI_ROOT}', $script:ResolvedAiRoot)
}

function Get-TreeStats {
    param([Parameter(Mandatory)][string]$Path)
    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction Stop)
    $bytes = ($files | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $bytes) { $bytes = 0 }
    return [pscustomobject]@{ Files = $files.Count; Bytes = [int64]$bytes }
}

function Test-TreeHashEquality {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    $sourceRoot = Resolve-FullPath $Source
    $destinationRoot = Resolve-FullPath $Destination
    $sourceFiles = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force -File |
        Sort-Object FullName)
    foreach ($file in $sourceFiles) {
        $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\')
        $target = Join-Path $destinationRoot $relative
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            throw "Missing destination file: $relative"
        }
        $targetInfo = Get-Item -LiteralPath $target -Force
        if ($file.Length -ne $targetInfo.Length) {
            throw "Size mismatch: $relative"
        }
        $sourceHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        if ($sourceHash -ne $targetHash) {
            throw "SHA256 mismatch: $relative"
        }
    }

    $sourceStats = Get-TreeStats $sourceRoot
    $destinationStats = Get-TreeStats $destinationRoot
    if ($destinationStats.Files -lt $sourceStats.Files -or
        $destinationStats.Bytes -lt $sourceStats.Bytes) {
        throw "Destination totals are smaller than source totals"
    }
    return $sourceStats
}

$script:ResolvedAiRoot = Resolve-FullPath $AiRoot
$script:ResolvedUserRoot = Resolve-FullPath $UserRoot
$allowedRoots = @($AllowedSourceRoot | ForEach-Object { Resolve-FullPath $_ })
$resolvedPlan = Resolve-FullPath $PlanPath
if (-not (Test-Path -LiteralPath $resolvedPlan -PathType Leaf)) {
    throw "Missing migration plan: $resolvedPlan"
}

$items = @(Get-Content -LiteralPath $resolvedPlan -Raw | ConvertFrom-Json)
if ($items.Count -eq 0) { throw 'Migration plan contains no items' }

foreach ($item in $items) {
    if (-not $item.name -or -not $item.source -or -not $item.destination) {
        throw 'Each plan item requires name, source, and destination'
    }
    $source = Assert-PathBelowRoot -Path (Expand-PlanPath $item.source) `
        -Root $allowedRoots -Role 'Source'
    $destination = Assert-PathBelowRoot -Path (Expand-PlanPath $item.destination) `
        -Root @($script:ResolvedAiRoot) -Role 'Destination'
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        throw "Missing source directory: $source"
    }

    Write-Host ("PLAN|{0}|{1}|{2}" -f $item.name, $source, $destination)
    if (-not $Apply) { continue }

    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    & robocopy.exe $source $destination /E /COPY:DAT /DCOPY:DAT /R:2 /W:2 /XJ /MT:16 /NP
    $copyExit = $LASTEXITCODE
    if ($copyExit -ge 8) {
        throw "Robocopy failed for $($item.name) with exit code $copyExit"
    }
    $stats = Test-TreeHashEquality -Source $source -Destination $destination
    Write-Host ("VERIFIED|{0}|files={1}|bytes={2}" -f
        $item.name, $stats.Files, $stats.Bytes)
}

if (-not $Apply) {
    Write-Host 'DRY_RUN_COMPLETE|Use -Apply after reviewing every resolved path.'
}
