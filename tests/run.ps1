# Runs every tests\*_test.lua on Lua 5.1 (same version as WoW) from the repo root.
# Exits non-zero when any test file fails. tools\check.ps1 calls this at the end.
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$lua = Join-Path $root "tools\bin\lua51\lua5.1.exe"
if (-not (Test-Path $lua)) { throw "Missing $lua. Run tools\setup-tools.ps1." }

$files = Get-ChildItem (Join-Path $root "tests") -Filter *_test.lua | Sort-Object Name
$failed = @()
Push-Location $root
try {
    foreach ($f in $files) {
        & $lua ("tests/" + $f.Name)
        if ($LASTEXITCODE -ne 0) { $failed += $f.Name }
    }
} finally {
    Pop-Location
}

if ($failed.Count -gt 0) {
    Write-Host "Tests failed: $($failed -join ', ')"
    exit 1
}
Write-Host "All tests passed ($($files.Count) files)."
exit 0
