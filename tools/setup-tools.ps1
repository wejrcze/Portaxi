# Downloads the dev tools into tools\bin (ignored by git). No admin rights, no PATH changes.
#   Lua 5.1.5 binaries (LuaBinaries, Win64) - the Lua version WoW uses
#   luacheck 1.2.0 standalone exe (lunarmodules/luacheck release)
$ErrorActionPreference = "Stop"
$bin = Join-Path $PSScriptRoot "bin"
$luaDir = Join-Path $bin "lua51"
New-Item -ItemType Directory -Force $luaDir | Out-Null

$luacheck = Join-Path $bin "luacheck.exe"
if (-not (Test-Path $luacheck)) {
    curl.exe -sSL -o $luacheck "https://github.com/lunarmodules/luacheck/releases/download/v1.2.0/luacheck.exe"
}

if (-not (Test-Path (Join-Path $luaDir "lua5.1.exe"))) {
    $zip = Join-Path $luaDir "lua-5.1.5_Win64_bin.zip"
    curl.exe -sSL -o $zip "https://sourceforge.net/projects/luabinaries/files/5.1.5/Tools%20Executables/lua-5.1.5_Win64_bin.zip/download"
    Expand-Archive $zip -DestinationPath $luaDir -Force
    Remove-Item $zip
}

& (Join-Path $luaDir "lua5.1.exe") -v
& $luacheck --version
