[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$SourcePath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DestinationDirectory,

    [string]$AssetRoot = $(if ($env:AI_ASSET_ROOT) { $env:AI_ASSET_ROOT } else { 'D:\AI' }),

    [string]$ManifestPath,

    [switch]$Apply,

    [switch]$RemoveSource,

    [switch]$AllowReparsePoint,

    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Test-PathInside {
    param(
        [Parameter(Mandatory = $true)][string]$Child,
        [Parameter(Mandatory = $true)][string]$Parent,
        [switch]$AllowEqual
    )

    $normalizedChild = Get-NormalizedPath $Child
    $normalizedParent = Get-NormalizedPath $Parent
    if ($AllowEqual -and $normalizedChild.Equals($normalizedParent, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $prefix = $normalizedParent + [IO.Path]::DirectorySeparatorChar
    return $normalizedChild.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

if ($RemoveSource -and -not $Apply) {
    throw '-RemoveSource requires -Apply.'
}

$assetRootPath = Get-NormalizedPath $AssetRoot
if (-not (Test-Path -LiteralPath $assetRootPath -PathType Container)) {
    throw "Asset root does not exist: $assetRootPath"
}

$policyPath = Join-Path $assetRootPath 'README.md'
if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) {
    throw "Asset policy is missing: $policyPath"
}

$destinationPath = Get-NormalizedPath $DestinationDirectory
if (-not (Test-PathInside -Child $destinationPath -Parent $assetRootPath)) {
    throw "Destination must be below the asset root: $destinationPath"
}

$sourceItems = @(foreach ($source in $SourcePath) {
    $resolved = Resolve-Path -LiteralPath $source -ErrorAction Stop
    Get-Item -LiteralPath $resolved.Path -Force
})

$duplicateSources = $sourceItems | Group-Object FullName | Where-Object Count -gt 1
if ($duplicateSources) {
    throw "Duplicate source path: $($duplicateSources[0].Name)"
}

$planItems = [Collections.Generic.List[object]]::new()
$fileEntries = [Collections.Generic.List[object]]::new()

foreach ($sourceItem in $sourceItems) {
    $sourceFullName = Get-NormalizedPath $sourceItem.FullName
    $targetItem = Join-Path $destinationPath $sourceItem.Name

    if ($sourceItem.PSIsContainer -and (Test-PathInside -Child $destinationPath -Parent $sourceFullName -AllowEqual)) {
        throw "Destination cannot equal or be nested inside a source directory: $sourceFullName"
    }

    $duplicateTarget = @($planItems | Where-Object { $_.TargetPath -eq $targetItem })
    if ((Test-Path -LiteralPath $targetItem) -or $duplicateTarget.Count -gt 0) {
        throw "Destination collision: $targetItem"
    }

    $treeItems = @($sourceItem)
    if ($sourceItem.PSIsContainer) {
        $treeItems += @(Get-ChildItem -LiteralPath $sourceFullName -Force -Recurse)
    }

    $reparseItems = @($treeItems | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    if ($reparseItems.Count -gt 0 -and -not $AllowReparsePoint) {
        throw "Reparse point found under source; inspect it before retrying: $($reparseItems[0].FullName)"
    }

    $sourceFiles = @(if ($sourceItem.PSIsContainer) {
        @($treeItems | Where-Object { -not $_.PSIsContainer })
    } else {
        @($sourceItem)
    })

    $totalBytes = [Int64](($sourceFiles | Measure-Object -Property Length -Sum).Sum)
    $planItems.Add([pscustomobject]@{
        SourcePath = $sourceFullName
        TargetPath = $targetItem
        Type       = if ($sourceItem.PSIsContainer) { 'directory' } else { 'file' }
        FileCount  = $sourceFiles.Count
        Bytes      = $totalBytes
    })

    foreach ($sourceFile in $sourceFiles) {
        $relativePath = if ($sourceItem.PSIsContainer) {
            [IO.Path]::GetRelativePath($sourceFullName, $sourceFile.FullName)
        } else {
            $sourceFile.Name
        }

        $destinationFile = if ($sourceItem.PSIsContainer) {
            Join-Path $targetItem $relativePath
        } else {
            $targetItem
        }

        $fileEntries.Add([pscustomobject]@{
            SourceFile      = $sourceFile.FullName
            DestinationFile = $destinationFile
            RelativePath    = Join-Path $sourceItem.Name $relativePath
            Bytes           = [Int64]$sourceFile.Length
            Sha256          = $null
        })
    }
}

$result = [ordered]@{
    Mode                 = if ($Apply) { if ($RemoveSource) { 'move' } else { 'copy' } } else { 'dry-run' }
    AssetRoot            = $assetRootPath
    PolicyPath           = $policyPath
    DestinationDirectory = $destinationPath
    SourceCount          = $sourceItems.Count
    FileCount            = $fileEntries.Count
    Bytes                = [Int64](($fileEntries | Measure-Object -Property Bytes -Sum).Sum)
    Collisions           = 0
    Items                = @($planItems)
    ManifestPath         = $null
    Verified             = $false
    SourcesRemoved       = $false
}

if (-not $Apply) {
    if ($AsJson) {
        $result | ConvertTo-Json -Depth 6
    } else {
        [pscustomobject]$result
    }
    return
}

foreach ($entry in $fileEntries) {
    $entry.Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $entry.SourceFile).Hash
}

New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
foreach ($planItem in $planItems) {
    Copy-Item -LiteralPath $planItem.SourcePath -Destination $destinationPath -Recurse
}

foreach ($entry in $fileEntries) {
    if (-not (Test-Path -LiteralPath $entry.DestinationFile -PathType Leaf)) {
        throw "Copied file is missing: $($entry.DestinationFile)"
    }

    $destinationFile = Get-Item -LiteralPath $entry.DestinationFile -Force
    if ([Int64]$destinationFile.Length -ne $entry.Bytes) {
        throw "Copied file size mismatch: $($entry.DestinationFile)"
    }

    $destinationHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $entry.DestinationFile).Hash
    if ($destinationHash -ne $entry.Sha256) {
        throw "Copied file hash mismatch: $($entry.DestinationFile)"
    }
}

if (-not $ManifestPath) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
    $ManifestPath = Join-Path (Join-Path $assetRootPath 'manifests') "$stamp-ai-asset-archive.json"
}

$manifestFullPath = Get-NormalizedPath $ManifestPath
if (-not (Test-PathInside -Child $manifestFullPath -Parent $assetRootPath)) {
    throw "Manifest must be below the asset root: $manifestFullPath"
}
if (Test-Path -LiteralPath $manifestFullPath) {
    throw "Manifest already exists: $manifestFullPath"
}

$manifestParent = Split-Path -Parent $manifestFullPath
New-Item -ItemType Directory -Path $manifestParent -Force | Out-Null
$manifest = [ordered]@{
    SchemaVersion = 1
    CreatedAt     = (Get-Date).ToString('o')
    Action        = if ($RemoveSource) { 'move' } else { 'copy' }
    AssetRoot     = $assetRootPath
    PolicyPath    = $policyPath
    Destination  = $destinationPath
    Items         = @($planItems)
    Files         = @($fileEntries | ForEach-Object {
        [ordered]@{
            RelativePath = $_.RelativePath
            Bytes        = $_.Bytes
            Sha256       = $_.Sha256
        }
    })
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestFullPath -Encoding utf8

if ($RemoveSource) {
    foreach ($sourceItem in $sourceItems) {
        Remove-Item -LiteralPath $sourceItem.FullName -Recurse:$sourceItem.PSIsContainer -Force
    }
}

$result.ManifestPath = $manifestFullPath
$result.Verified = $true
$result.SourcesRemoved = [bool]$RemoveSource
if ($AsJson) {
    $result | ConvertTo-Json -Depth 6
} else {
    [pscustomobject]$result
}
