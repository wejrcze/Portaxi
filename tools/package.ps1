# Builds the release zip for CurseForge (or a GitHub release):
#   dist\Portaxi-<version>.zip  with a single top-level "Portaxi\" folder inside.
# The version is read from "## Version:" in Portaxi\Portaxi.toc. Runs tools\check.ps1 first.
param([switch]$SkipCheck)
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$addon = Join-Path $root "Portaxi"

if (-not $SkipCheck) {
    & (Join-Path $PSScriptRoot "check.ps1")
    if ($LASTEXITCODE -ne 0) { throw "check.ps1 failed; fix it before packaging." }
}

$versionLine = Get-Content (Join-Path $addon "Portaxi.toc") | Where-Object { $_ -match '^## Version:\s*(.+)$' } | Select-Object -First 1
if (-not $versionLine) { throw "No '## Version:' line in Portaxi.toc." }
$version = ($versionLine -replace '^## Version:\s*', '').Trim()

$dist = Join-Path $root "dist"
New-Item -ItemType Directory -Force $dist | Out-Null
$zip = Join-Path $dist "Portaxi-$version.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }

# Zip entries must use "/" and live under "Portaxi/"; Compress-Archive on Windows PowerShell writes "\",
# which some unpackers mishandle, so build the archive by hand.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::Open($zip, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    Get-ChildItem $addon -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($addon.Length + 1).Replace("\", "/")
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive, $_.FullName, "Portaxi/$rel", [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally {
    $archive.Dispose()
}

$count = (Get-ChildItem $addon -Recurse -File).Count
Write-Host "Built $zip ($count files, version $version)"
