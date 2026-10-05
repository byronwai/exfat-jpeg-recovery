# phase2_control.ps1 - positive control for the carver (synthetic drill)
#
# Before pointing the carver at a real volume, prove the pipeline end to end on
# data whose ground truth is known:
#   1. build two JPEGs with GDI+ and stamp DateTimeOriginal (0x9003) -
#      one in the keep window, one outside it (decoy),
#   2. embed them plus a TRUNCATED copy (header + half the entropy stream, no
#      EOI) into a zeroed container at known offsets,
#   3. run carver.exe over a one-run byte map of that container,
#   4. byte-compare the carved match against the original file.
#
# Pass criteria: 1 match + 1 _TRUNC match saved, 0 near, decoy counted as
# discarded_date, carved bytes identical to the original JPEG.
#
# Usage: .\phase2_control.ps1 [-RecoveryDir $PSScriptRoot]

param(
    [string]$RecoveryDir = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function New-TestJpeg([string]$Path, [string]$ExifDate, [int]$Hue) {
    # base JPEG from GDI+ (SOI ... EOI), no metadata
    $bmp = New-Object System.Drawing.Bitmap 800, 600
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $rect = New-Object System.Drawing.Rectangle 0, 0, 800, 600
    $c1 = [System.Drawing.Color]::FromArgb(255, $Hue, 120, 40)
    $c2 = [System.Drawing.Color]::FromArgb(255, 40, ($Hue + 80) % 256, 200)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $c1, $c2, 45.0)
    $g.FillRectangle($brush, $rect)
    $g.Dispose()
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    $bmp.Dispose()
    $jpg = [IO.File]::ReadAllBytes($Path)

    # splice a minimal Exif APP1 right after SOI (PropertyItem is not usable in
    # every PS environment, and a hand-built TIFF exercises the carver's real
    # path: IFD0 -> tag 0x8769 -> Exif IFD -> tag 0x9003):
    #   "Exif\0\0" | II 42 @8 | IFD0: 1 entry (0x8769 -> 26) next=0
    #   ExifIFD @26: 1 entry (0x9003, ASCII, count 20 -> 44) next=0 | data @44
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([byte[]](0x45, 0x78, 0x69, 0x66, 0, 0))          # "Exif\0\0"
    $bw.Write([byte[]](0x49, 0x49))                            # II
    $bw.Write([uint16]42)
    $bw.Write([uint32]8)                                       # IFD0 @ 8
    $bw.Write([uint16]1)                                       # IFD0: 1 entry
    $bw.Write([uint16]0x8769)                                  # ExifIFD pointer tag
    $bw.Write([uint16]4)                                       # type LONG
    $bw.Write([uint32]1)                                       # count
    $bw.Write([uint32]26)                                      # Exif IFD offset
    $bw.Write([uint32]0)                                       # next IFD = none
    $bw.Write([uint16]1)                                       # Exif IFD: 1 entry
    $bw.Write([uint16]0x9003)                                  # DateTimeOriginal
    $bw.Write([uint16]2)                                       # type ASCII
    $bw.Write([uint32]20)                                      # count (19 + NUL)
    $bw.Write([uint32]44)                                      # value offset
    $bw.Write([uint32]0)                                       # next IFD = none
    $bw.Write([Text.Encoding]::ASCII.GetBytes($ExifDate))      # 19 chars
    $bw.Write([byte]0)
    $bw.Flush()
    $payload = $ms.ToArray()
    $bw.Close()

    $app1 = New-Object System.IO.MemoryStream
    $b2 = New-Object System.IO.BinaryWriter($app1)
    $b2.Write([byte]0xFF); $b2.Write([byte]0xE1)               # APP1 marker
    $segLen = $payload.Length + 2
    $b2.Write([byte](($segLen -shr 8) -band 0xFF)); $b2.Write([byte]($segLen -band 0xFF))
    $b2.Write($payload)
    $b2.Flush()
    $seg = $app1.ToArray()
    $b2.Close()

    $out = New-Object byte[] (2 + $seg.Length + $jpg.Length - 2)
    $out[0] = 0xFF; $out[1] = 0xD8                              # SOI
    [Array]::Copy($seg, 0, $out, 2, $seg.Length)               # APP1 Exif
    [Array]::Copy($jpg, 2, $out, 2 + $seg.Length, $jpg.Length - 2)
    [IO.File]::WriteAllBytes($Path, $out)
    , $out
}

$dir = Join-Path $RecoveryDir 'selftest'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

# --- 1. ground-truth JPEGs ------------------------------------------------------
$refB  = New-TestJpeg (Join-Path $dir 'ref_match.jpg')  '2026:09:06 19:19:23' 200
$decB  = New-TestJpeg (Join-Path $dir 'ref_decoy.jpg')  '2026:09:13 12:00:00' 20
Write-Host ("ground truth: match jpeg {0} B, decoy jpeg {1} B" -f $refB.Length, $decB.Length)

# --- 2. container: zeros + known offsets (0x30000 match, 0xC0000 decoy, 0x140000 truncated half) ---
$SIZE = 3MB
$cont = New-Object byte[] $SIZE
[Array]::Copy($refB, 0, $cont, 0x30000, $refB.Length)
[Array]::Copy($decB, 0, $cont, 0xC0000, $decB.Length)
[Array]::Copy($refB, 0, $cont, 0x140000, [int]($refB.Length / 2))   # cut mid-entropy, no EOI
$container = Join-Path $dir 'container.bin'
[IO.File]::WriteAllBytes($container, $cont)

$runsCsv = Join-Path $dir 'byte_runs.csv'
'start_offset,length' | Set-Content -Path $runsCsv
("0,{0}" -f $SIZE)   | Add-Content -Path $runsCsv

# --- 3. carve the container ------------------------------------------------------
$exe = Join-Path $RecoveryDir 'carver.exe'
if (-not (Test-Path $exe)) { throw "missing $exe - run phase3_carve.ps1 (compile step) first, or csc /out:carver.exe carver.cs" }
$found = Join-Path $dir 'found'
& $exe $container $runsCsv $found '2026:09:06' '2026:09:05' '2026:09:07' '2026:09:08'
if ($LASTEXITCODE -ne 0) { throw "carver exited $LASTEXITCODE" }

# --- 4. verify -------------------------------------------------------------------
$fail = @()
# NB: do not name this $matches - it collides with the automatic $Matches
# variable, which every -match/-notmatch invocation overwrites.
$matchFiles = @(Get-ChildItem (Join-Path $found 'match') -Filter *.jpg -ErrorAction SilentlyContinue)
$nears      = @(Get-ChildItem (Join-Path $found 'near')  -Filter *.jpg -ErrorAction SilentlyContinue)
$full       = @($matchFiles | Where-Object { $_.Name -notlike '*_TRUNC*' })
$trunc      = @($matchFiles | Where-Object { $_.Name -like '*_TRUNC*' })

if ($matchFiles.Count -ne 2) { $fail += "expected 2 match files (full + TRUNC), got $($matchFiles.Count)" }
if ($nears.Count   -ne 0) { $fail += "expected 0 near files, got $($nears.Count)" }
if ($full.Count   -ne 1)  { $fail += "expected 1 full match, got $($full.Count)" }
if ($trunc.Count  -ne 1)  { $fail += "expected 1 TRUNC match, got $($trunc.Count)" }
if (Get-ChildItem $found -Recurse -Filter '*.jpg' | Where-Object { $_.Name -like '*0913*' }) { $fail += 'decoy (0913) leaked into output' }

if ($full.Count -eq 1) {
    $carved = [IO.File]::ReadAllBytes($full[0].FullName)
    if ($carved.Length -ne $refB.Length) {
        $fail += ("carved size {0} != original {1}" -f $carved.Length, $refB.Length)
    } elseif (-not [Linq.Enumerable]::SequenceEqual([byte[]]$carved, [byte[]]$refB)) {
        $fail += 'carved bytes differ from original'
    } else {
        Write-Host ("byte-identical: {0} ({1} B)" -f $full[0].Name, $carved.Length)
    }
}
if ($trunc.Count -eq 1) {
    $t = [IO.File]::ReadAllBytes($trunc[0].FullName)
    $expected = $SIZE - 0x140000                                  # runs to the run boundary
    if ($t.Length -ne $expected) { $fail += ("TRUNC size {0} != run-boundary size {1}" -f $t.Length, $expected) }
    else { Write-Host ("truncated frame saved to run boundary: {0} ({1} B)" -f $trunc[0].Name, $t.Length) }
}

if ($fail.Count) { $fail | ForEach-Object { Write-Host "FAIL: $_" -ForegroundColor Red }; exit 1 }
Write-Host 'PHASE 2 POSITIVE CONTROL: PASS' -ForegroundColor Green
