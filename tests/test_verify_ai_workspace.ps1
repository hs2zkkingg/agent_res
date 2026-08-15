$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$script = Join-Path $repoRoot 'scripts\verify_ai_workspace.ps1'
$registry = Join-Path $repoRoot 'config\ai-projects.json'

$output = @(& $script -RegistryPath $registry -ValidateOnly)
if ($output -notcontains 'HEALTH=PASS') {
    throw 'Valid AI project registry was rejected'
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('agent-res-registry-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    $invalid = Join-Path $tempRoot 'duplicate.json'
    @{
        schema_version = 1
        projects = @(
            @{ id = 'duplicate'; kind = 'authoritative'; root = 'C:\one' },
            @{ id = 'duplicate'; kind = 'third-party'; root = 'C:\two' }
        )
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $invalid -Encoding UTF8
    $rejected = $false
    try { & $script -RegistryPath $invalid -ValidateOnly | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Duplicate registry ids were accepted' }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}

Write-Output 'PASS verify_ai_workspace'
