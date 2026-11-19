# Junctions the repo's Portaxi/ folder into the game's AddOns folder, so edits are live after /reload.
# A junction needs no admin rights. Run again any time; it does nothing if the link already exists.
param(
    [string]$WowPath = "F:\World of Warcraft\_forever_"
)
$ErrorActionPreference = "Stop"

$target = (Resolve-Path (Join-Path $PSScriptRoot "..\Portaxi")).Path
$addons = Join-Path $WowPath "Interface\AddOns"
if (-not (Test-Path $addons)) { throw "AddOns folder not found: $addons" }

$link = Join-Path $addons "Portaxi"
if (Test-Path $link) {
    $item = Get-Item $link -Force
    if ($item.LinkType -eq "Junction" -and (@($item.Target) -contains $target)) {
        Write-Host "Already linked: $link -> $target"
        return
    }
    throw "$link already exists and is not a junction to $target. Move or delete it first."
}

New-Item -ItemType Junction -Path $link -Target $target | Out-Null
Write-Host "Linked: $link -> $target"
