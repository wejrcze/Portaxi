# Checks the addon before an in-game /reload:
#   1. luac 5.1 syntax check (same Lua as WoW)
#   2. luacheck
#   3. every .lua file of the addon is listed in Portaxi.toc and every TOC entry exists
#   4. offline tests (tests\run.ps1)
# Exits non-zero on any failure. Run tools\setup-tools.ps1 first on a new machine.
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$addon = Join-Path $root "Portaxi"
$luac = Join-Path $PSScriptRoot "bin\lua51\luac5.1.exe"
$luacheck = Join-Path $PSScriptRoot "bin\luacheck.exe"
foreach ($tool in $luac, $luacheck) {
    if (-not (Test-Path $tool)) { throw "Missing $tool. Run tools\setup-tools.ps1." }
}

$failed = $false
$files = Get-ChildItem $addon -Recurse -Filter *.lua | Where-Object { $_.FullName -notmatch '\\Libs\\' }
foreach ($f in $files) {
    & $luac -p $f.FullName
    if ($LASTEXITCODE -ne 0) { $failed = $true }
}

Push-Location $root
try {
    & $luacheck Portaxi --codes
    if ($LASTEXITCODE -ne 0) { $failed = $true }
} finally {
    Pop-Location
}

# TOC completeness (playbook D7)
$toc = Get-Content (Join-Path $addon "Portaxi.toc") |
    Where-Object { $_.Trim() -ne "" -and -not $_.StartsWith("#") } |
    ForEach-Object { $_.Trim().Replace("/", "\") }
$onDisk = $files | ForEach-Object { $_.FullName.Substring($addon.Length + 1) }
foreach ($f in $onDisk) {
    if ($toc -notcontains $f) { Write-Host "Not in Portaxi.toc: $f"; $failed = $true }
}
foreach ($t in $toc) {
    if (-not (Test-Path (Join-Path $addon $t))) { Write-Host "Listed in Portaxi.toc but missing: $t"; $failed = $true }
}

$tests = Join-Path $root "tests\run.ps1"
if (Test-Path $tests) {
    & $tests
    if ($LASTEXITCODE -ne 0) { $failed = $true }
}

if ($failed) { Write-Host "Checks failed."; exit 1 }
Write-Host "All checks passed ($($files.Count) Lua files)."
exit 0
