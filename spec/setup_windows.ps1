#!/usr/bin/env pwsh
<#
.SYNOPSIS
    One-command setup: install MinGW + LuaRocks + deps, then run tests.

.DESCRIPTION
    Installs (per-user, no admin needed unless winget requires it):
      1. MinGW-w64 UCRT   via winget (C compiler, needed for Lua C rocks)
      2. LuaRocks 3.12.2  standalone from luarocks.github.io (bundles LuaJIT)
      3. Rocks: luafilesystem, lua-cjson, luajson
    Then runs tests with bundled LuaJIT.

    Lua 5.4 from LuaBinaries is optional (uncomment section below).

    Idempotent — already-installed components are skipped.

.PARAMETER SkipTests
    If set, installs everything but skips the test run.

.EXAMPLE
    .\spec\setup_windows.ps1
    .\spec\setup_windows.ps1 -SkipTests
#>

param([switch]$SkipTests)

$ErrorActionPreference = "Stop"
$start = Get-Date

# ---------- prerequisites ----------
$winget = Get-Command winget.exe -ErrorAction SilentlyContinue
if (-not $winget) {
    Write-Host ""
    Write-Host "ERROR: winget not found." -ForegroundColor Red
    Write-Host ""
    Write-Host "winget е нужен за инсталиране на MinGW-w64 (C компилатор)."
    Write-Host "Инсталирай го от Microsoft Store:"
    Write-Host "  https://www.microsoft.com/p/app-installer/9nblggh4nns1"
    Write-Host ""
    Write-Host "Или през PowerShell (като admin):"
    Write-Host "  Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe"
    Write-Host ""
    Write-Host "След това пробвай ръчния setup от spec/README.md."
    exit 1
}

# ---------- paths ----------
$rocksDir  = "$env:USERPROFILE\luarocks"
$rocksExe  = "$rocksDir\luarocks.exe"
$archRocks = if ([Environment]::Is64BitOperatingSystem) { "64" } else { "32" }

# LuaJIT is bundled with standalone LuaRocks; find the bin dir.
$luajitDir = if (Test-Path "$rocksDir\luajit.exe") {
    $rocksDir
} elseif (Test-Path "$env:USERPROFILE\AppData\Local\Programs\LuaJIT\bin\luajit.exe") {
    "$env:USERPROFILE\AppData\Local\Programs\LuaJIT\bin"
} else {
    $null
}

# ---------- helpers ----------
function Step($Title) {
    Write-Host ""
    Write-Host "--- $Title ---" -ForegroundColor Cyan
}

function Ok($Msg) {
    Write-Host "  [OK] $Msg" -ForegroundColor Green
}

function Wrn($Msg) {
    Write-Host "  [!] $Msg" -ForegroundColor Yellow
}

function Add-ToUserPath($Path) {
    $current = [Environment]::GetEnvironmentVariable("PATH", "User")
    $parts   = $current -split ";" | Where-Object { $_ -and $_ -ne $Path }
    $new     = "$Path;$($parts -join ';')"
    [Environment]::SetEnvironmentVariable("PATH", $new, "User")
    if ($env:PATH -split ";" -notcontains $Path) {
        $env:PATH = "$Path;$env:PATH"
    }
    Ok "Added $Path to PATH"
}

# =================================================================
# 1. MinGW-w64 (C compiler for Lua rocks)
# =================================================================
Step "MinGW-w64 (C compiler)"

$needGcc = $null -eq (Get-Command gcc.exe -ErrorAction SilentlyContinue)

if ($needGcc) {
    Write-Host "  Installing MinGW-w64 UCRT via winget ..."
    winget install -e --id BrechtSanders.WinLibs.POSIX.UCRT --accept-package-agreements 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "winget install MinGW failed (try running as admin)"
    }
    Ok "MinGW-w64 installed (restart shell or run: `$env:PATH = ...mingw64\bin` to use)"
} else {
    Ok "Already present: $(where.exe gcc 2>$null | Select-Object -First 1)"
}

# =================================================================
# 2. LuaRocks (standalone — bundles LuaJIT)
# =================================================================
Step "LuaRocks"

$needRocks = -not (Test-Path $rocksExe)

if ($needRocks) {
    New-Item -ItemType Directory -Path $rocksDir -Force | Out-Null
    $rocksUrl = "https://luarocks.github.io/luarocks/releases/luarocks-3.12.2-windows-${archRocks}.zip"
    $zip = "$env:TEMP\luarocks.zip"
    Write-Host "  Downloading ..." -NoNewline
    curl.exe -sSL -o $zip $rocksUrl 2>$null
    if ($LASTEXITCODE -ne 0) { throw "curl failed" }
    Write-Host " done" -ForegroundColor Green
    Expand-Archive -Path $zip -DestinationPath $rocksDir -Force
    Remove-Item -Force $zip
    $sub = Get-ChildItem "$rocksDir\luarocks-*" -Directory | Select-Object -First 1
    if ($sub) {
        Get-ChildItem $sub.FullName | Move-Item -Destination $rocksDir -Force
        Remove-Item -Recurse -Force $sub.FullName
    }
    Add-ToUserPath $rocksDir

    # Locate bundled LuaJIT
    $luajitDir = $rocksDir
} else {
    Ok "Already present: $rocksExe"
}

# Configure luarocks to use its bundled LuaJIT (not an external Lua).
# The standalone luarocks knows about its own LuaJIT; we just need to
# clear any stale Lua 5.4 references from earlier config.
$luajitDir = if (Test-Path "$rocksDir\luajit.exe") { $rocksDir } else { $luajitDir }
$configFile = if (Test-Path "$rocksDir\..\..\LuaJIT\etc\luarocks\config.lua") {
    Resolve-Path "$rocksDir\..\..\LuaJIT\etc\luarocks\config.lua"
} elseif (Test-Path "$env:APPDATA\luarocks\config.lua") {
    "$env:APPDATA\luarocks\config.lua"
} else { $null }

if ($configFile -and (Test-Path $configFile)) {
    $content = Get-Content $configFile -Raw
    if ($content -match 'lua_interpreter\s*=\s*"lua\.exe"') {
        # Reset config to use bundled LuaJIT
@'
lua_interpreter = "luajit"
lua_version = "5.1"
'@ | Set-Content $configFile
        Ok "LuaRocks configured for bundled LuaJIT"
    } else {
        Wrn "Config exists but lua_interpreter is not lua.exe — leaving as-is"
    }
}

$env:PATH = if ($luajitDir) { "$luajitDir;$rocksDir;$env:PATH" } else { "$rocksDir;$env:PATH" }

# =================================================================
# 3. Rocks (luafilesystem, lua-cjson, luajson)
# =================================================================
Step "LuaRocks packages"

$rockList = @("luafilesystem", "lua-cjson", "luajson")

foreach ($rock in $rockList) {
    $installed = & $rocksExe list --porcelain 2>$null |
        Where-Object { $_ -match "^$rock\s" }
    if ($installed) {
        Ok "$rock already installed"
    } else {
        Write-Host "  Installing $rock ..." -NoNewline
        & $rocksExe install $rock 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host " done" -ForegroundColor Green
        } else {
            Write-Host " FAILED" -ForegroundColor Red
            throw "luarocks install $rock failed"
        }
    }
}

# Smoke test — use LuaJIT (bundled with luarocks), NOT Lua 5.4.
$ljExe = if ($luajitDir) { "$luajitDir\luajit.exe" } else { "$rocksDir\luajit.exe" }
if (-not (Test-Path $ljExe)) {
    # Fallback to common install paths
    $ljExe = Get-ChildItem -Recurse -Filter "luajit.exe" "$env:USERPROFILE\AppData\Local\Programs\LuaJIT" 2>$null |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $ljExe) { $ljExe = "luajit.exe" }

Write-Host "  Smoke test:" -NoNewline
$smoke = @'
local ok, lfs = pcall(require, "lfs"); io.write(ok and "lfs OK " or "lfs FAIL ")
local ok2, json = pcall(require, "rapidjson"); if not ok2 then ok2, json = pcall(require, "cjson") end; io.write(ok2 and "json OK " or "json FAIL ")
io.write("luasocket not required")
'@
& $ljExe -e $smoke 2>&1 | ForEach-Object { Write-Host " $_" -NoNewline }
Write-Host ""

# =================================================================
# 4. Run tests
# =================================================================
if (-not $SkipTests) {
    Step "Running tests with $ljExe"
    $testRoot = Split-Path -Parent $PSScriptRoot
    Push-Location $testRoot
    & $ljExe spec/run_tests.lua
    $exitCode = $LASTEXITCODE
    Pop-Location

    $elapsed = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
    Write-Host ""
    Write-Host "Total time: ${elapsed}s" -ForegroundColor Cyan
    if ($exitCode -eq 0) {
        Write-Host "SUCCESS" -ForegroundColor Green
    } else {
        Write-Host "TESTS FAILED (exit code $exitCode)" -ForegroundColor Red
    }
    exit $exitCode
} else {
    Write-Host ""
    Write-Host "Setup complete. Run tests with:" -ForegroundColor Cyan
    Write-Host "  $ljExe spec/run_tests.lua" -ForegroundColor Yellow
}
