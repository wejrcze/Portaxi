#Requires -Version 7
# Releases the current version to CurseForge (public name ForeverPortaxi, project 1816274).
#
#   tools\release.ps1                          dry run: checks, builds the zip, prints what would be uploaded
#   tools\release.ps1 -Upload                  uploads it as a beta
#   tools\release.ps1 -Upload -ReleaseType release
#
# Steps: the version comes from "## Version:" in Portaxi\Portaxi.toc and must not be a "-dev" build; Portaxi\
# must have no uncommitted changes (the zip is built from the working tree); tools\package.ps1 runs check.ps1
# and builds dist\ForeverPortaxi-<version>.zip; the changelog is the matching entry of Portaxi\Changelog.lua;
# the game version id is looked up by name in the "WoW Forever" type.
#
# Token: the CurseForge upload token is read from the user environment variable CURSEFORGE_API_TOKEN, never
# from the repo, and is never printed. The upload API only adds files: the project description, logo and
# settings are edited on the website.
param(
    [ValidateSet("alpha", "beta", "release")][string]$ReleaseType = "beta",
    [string]$GameVersion = "1.60.1",
    [switch]$Upload,
    [switch]$AllowDirty
)
$ErrorActionPreference = "Stop"
$ProjectId = 1816274
$Api = "https://wow.curseforge.com/api"
$ForeverTypeId = 88568 # game version type "WoW Forever"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$addon = Join-Path $root "Portaxi"

# 1. Version
$versionLine = Get-Content (Join-Path $addon "Portaxi.toc") | Where-Object { $_ -match '^## Version:\s*(.+)$' } |
    Select-Object -First 1
if (-not $versionLine) { throw "No '## Version:' line in Portaxi.toc." }
$version = ($versionLine -replace '^## Version:\s*', '').Trim()
if ($version -match '-') { throw "Version $version is a pre-release build; bump it to a release version first." }

# 2. Committed state only
$dirty = git -C $root status --porcelain -- Portaxi
if ($dirty -and -not $AllowDirty) {
    throw "Portaxi\ has uncommitted changes; commit them first (or pass -AllowDirty for a test build):`n$($dirty -join "`n")"
}

# 3. Changelog entry, read with the same Lua 5.1 as the game
$lua = Join-Path $PSScriptRoot "bin\lua51\lua5.1.exe"
if (-not (Test-Path $lua)) { throw "Missing $lua. Run tools\setup-tools.ps1." }
$luaScript = Join-Path ([IO.Path]::GetTempPath()) "portaxi-changelog.lua"
Set-Content -Path $luaScript -Encoding utf8NoBOM -Value @'
local ns = {}
assert(loadfile(arg[1]))("Portaxi", ns)
for _, e in ipairs(ns.Changelog or {}) do
  if e.version == arg[2] then
    for _, item in ipairs(e.items) do print("- " .. item) end
    os.exit(0)
  end
end
os.exit(3)
'@
$prevEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = [Text.Encoding]::UTF8
try {
    $changelogLines = & $lua $luaScript (Join-Path $addon "Changelog.lua") $version
    $luaExit = $LASTEXITCODE
} finally {
    [Console]::OutputEncoding = $prevEncoding
    Remove-Item $luaScript -Force -ErrorAction SilentlyContinue
}
if ($luaExit -ne 0 -or -not $changelogLines) { throw "No entry for $version in Portaxi\Changelog.lua." }
$changelog = ($changelogLines -join "`n")

# 4. Checks and zip
& (Join-Path $PSScriptRoot "package.ps1")
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "package.ps1 failed." }
$zip = Join-Path $root "dist\ForeverPortaxi-$version.zip"
if (-not (Test-Path $zip)) { throw "Expected $zip after packaging." }

# 5. Token and game version id
$token = $env:CURSEFORGE_API_TOKEN
if (-not $token) { $token = [Environment]::GetEnvironmentVariable("CURSEFORGE_API_TOKEN", "User") }
if (-not $token) { throw "Set the user environment variable CURSEFORGE_API_TOKEN (see CLAUDE.md, Releasing)." }
$headers = @{ "X-Api-Token" = $token }
$versions = Invoke-RestMethod -Uri "$Api/game/versions" -Headers $headers -TimeoutSec 60
$forever = $versions | Where-Object { $_.gameVersionTypeID -eq $ForeverTypeId }
$gv = $forever | Where-Object { $_.name -eq $GameVersion } | Select-Object -First 1
if (-not $gv) {
    throw "No WoW Forever game version '$GameVersion' on CurseForge. Known: $(($forever.name | Sort-Object) -join ', ')"
}

# 6. Already released? (the public list shows approved files only)
$displayName = "ForeverPortaxi $version"
try {
    $public = Invoke-RestMethod -Uri "https://www.curseforge.com/api/v1/mods/$ProjectId/files?pageIndex=0&pageSize=50" -TimeoutSec 30
    $same = @($public.data | Where-Object { $_.displayName -eq $displayName -or $_.fileName -eq (Split-Path $zip -Leaf) })
    if ($same.Count -gt 0) { throw "CurseForge already has $displayName. Bump the version." }
} catch {
    if ($_.Exception.Message -like "CurseForge already has*") { throw }
    Write-Warning "Could not read the public file list: $($_.Exception.Message)"
}

# 7. Preview
$metadata = [ordered]@{
    changelog     = $changelog
    changelogType = "markdown"
    displayName   = $displayName
    gameVersions  = @([int]$gv.id)
    releaseType   = $ReleaseType
} | ConvertTo-Json -Compress
$size = "{0:N0}" -f (Get-Item $zip).Length
Write-Host ""
Write-Host "CurseForge project $ProjectId (ForeverPortaxi)"
Write-Host "  file:          $zip ($size bytes)"
Write-Host "  display name:  $displayName"
Write-Host "  release type:  $ReleaseType"
Write-Host "  game version:  WoW Forever $($gv.name) (id $($gv.id))"
Write-Host "  changelog:"
$changelogLines | ForEach-Object { Write-Host "    $_" }
Write-Host ""

if (-not $Upload) {
    Write-Host "Dry run, nothing uploaded. Add -Upload to send it."
    exit 0
}

# 8. Upload
$result = Invoke-RestMethod -Method Post -Uri "$Api/projects/$ProjectId/upload-file" -Headers $headers -TimeoutSec 300 `
    -Form @{ metadata = $metadata; file = Get-Item $zip }
Write-Host "Uploaded: CurseForge file id $($result.id). It shows on the project after moderation."
Write-Host "Tag the release: git tag v$version; git push origin v$version"
