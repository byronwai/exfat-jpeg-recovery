# phase3_carve.ps1 - compile + run the targeted carver against the free-run map
#
# Phase 1 mapped the free runs (byte_runs.csv); phase 2 proved the carver on a
# synthetic positive control (phase2_control.ps1). This phase compiles carver.cs
# with whatever csc.exe is available (PATH first, then the .NET Framework
# compiler that ships with Windows) and runs it against the volume.
#
# Why not photorec/foremost here: the carver only reads the ~128 GB of mapped
# free space (not 3.6 TB), validates marker structure to kill false positives,
# finds the true EOI past Canon's embedded thumbnail, and saves ONLY frames whose
# EXIF DateTimeOriginal falls in the keep window - the off-the-shelf flow cannot
# filter by capture date and buries the target shoot under every other fragment
# on the disk. (photorec_win 7.2 also carries a requireAdministrator manifest, so
# a scripted launch dies on a UAC prompt with exit code 1.)
#
# Usage (elevated shell - raw \\.\X: reads need it):
#   .\phase3_carve.ps1                                  # defaults below
#   .\phase3_carve.ps1 -Volume E: -KeepDate '2026:09:06' -NearDates '2026:09:05','2026:09:07','2026:09:08'
#
# Outputs under <RecoveryDir>\found:
#   match\  - EXIF DateTimeOriginal == KeepDate   (the 06-Sept shoot)
#   near\   - EXIF DateTimeOriginal in NearDates  (05/07/08-Sept context frames)
#   manifest.csv - path,exif,size,truncated,offset (appended across reruns)

param(
    [string]$Volume      = 'E:',
    [string]$RecoveryDir = $PSScriptRoot,
    [string]$KeepDate    = '2026:09:06',
    [string[]]$NearDates = @('2026:09:05', '2026:09:07', '2026:09:08')
)

$ErrorActionPreference = 'Stop'
$sw = [Diagnostics.Stopwatch]::StartNew()

# powershell -File does not strip quotes when launched from cmd - harden the args
$KeepDate = $KeepDate.Trim("'", '"').Trim()
$NearDates = @($NearDates | ForEach-Object { $_.Trim("'", '"').Trim() } | Where-Object { $_ })

# raw \\.\X: reads require elevation
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning 'not elevated: raw \\.\X: reads will fail - run this from an Administrator shell'
}

# --- 1. locate a C# compiler ---------------------------------------------------
$csc = $null
$cmd = Get-Command csc.exe -ErrorAction SilentlyContinue
if ($cmd) { $csc = $cmd.Source }
if (-not $csc) {
    $csc = Get-ChildItem "$env:WINDIR\Microsoft.NET\Framework64\v*\csc.exe" -ErrorAction SilentlyContinue |
        Sort-Object { [version]$_.Directory.Name.TrimStart('v') } -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $csc) { throw 'no csc.exe found (PATH or %WINDIR%\Microsoft.NET\Framework64)' }
Write-Host "compiler: $csc"

# --- 2. compile (Framework csc is C# 5 - carver.cs is written accordingly) -----
$src = Join-Path $RecoveryDir 'carver.cs'
$exe = Join-Path $RecoveryDir 'carver.exe'
if (-not (Test-Path $src)) { throw "missing $src" }
& $csc /nologo /out:$exe $src
if ($LASTEXITCODE -ne 0) { throw "compile failed (exit $LASTEXITCODE)" }
Write-Host "built: $exe"

# --- 3. run against the phase-1 free-run map ------------------------------------
$runsCsv = Join-Path $RecoveryDir 'byte_runs.csv'
if (-not (Test-Path $runsCsv)) { throw "missing $runsCsv - run phase1_map.ps1 first" }
$outDir = Join-Path $RecoveryDir 'found'

# 'E:' style targets the raw \\.\E: device; anything else is an image file path
$volArg = if ($Volume -match '^[A-Za-z]:$') { '\\.\' + $Volume } else { $Volume }
$argList = @($volArg, $runsCsv, $outDir, $KeepDate) + $NearDates
Write-Host ("carver.exe {0}" -f ($argList -join ' '))
& $exe @argList
if ($LASTEXITCODE -ne 0) { throw "carver failed (exit $LASTEXITCODE)" }

$sw.Stop()
$m = Get-ChildItem (Join-Path $outDir 'match') -Filter *.jpg -ErrorAction SilentlyContinue
$n = Get-ChildItem (Join-Path $outDir 'near')  -Filter *.jpg -ErrorAction SilentlyContinue
Write-Host ('phase3 done in {0:F0}s: match={1} near={2} files - see manifest.csv' -f $sw.Elapsed.TotalSeconds, @($m).Count, @($n).Count)
