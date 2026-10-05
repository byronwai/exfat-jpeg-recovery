# make_mini_exfat.ps1 - builds a synthetic mini exFAT image with known free runs
# and checks phase1_map.ps1 parses it correctly (self-test for phase 1).
$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
$repoRoot = Split-Path $dir -Parent
$img = Join-Path $dir 'mini.exfat'

# geometry: 512 B sectors, 8 sectors/cluster (4 KB), FAT @ sector 2 (1 sector),
# heap @ sector 4, 64 clusters (2..65), root dir = cluster 2, bitmap = cluster 3
$bps = 512; $heapOff = 4; $count = 64; $cs = 4096
$bytes = New-Object byte[] (516 * 512)

# NB: keep the shift operand [long] - PowerShell's -shr masks the count to 31
# bits for Int32, so `8 -shr 32` returns 8, not 0.
function W16($b, $o, $v) { $b[$o] = [byte]($v -band 255); $b[$o + 1] = [byte](([long]$v -shr 8) -band 255) }
function W32($b, $o, $v) { for ($i = 0; $i -lt 4; $i++) { $b[$o + $i] = [byte](([long]$v -shr (8 * $i)) -band 255) } }
function W64($b, $o, $v) { for ($i = 0; $i -lt 8; $i++) { $b[$o + $i] = [byte](([long]$v -shr (8 * $i)) -band 255) } }

# boot sector
[Array]::Copy([byte[]](0xEB, 0x76, 0x90), 0, $bytes, 0, 3)
[Array]::Copy([Text.Encoding]::ASCII.GetBytes('EXFAT   '), 0, $bytes, 3, 8)
W64 $bytes 0x48 516      # VolumeLength (sectors)
W32 $bytes 0x50 2        # FATOffset
W32 $bytes 0x54 1        # FATLength
W32 $bytes 0x58 $heapOff # ClusterHeapOffset
W32 $bytes 0x5C $count   # ClusterCount
W32 $bytes 0x60 2        # FirstClusterOfRootDirectory
$bytes[0x6C] = 9         # BytesPerSectorShift -> 512
$bytes[0x6D] = 3         # SectorsPerClusterShift -> 8

# FAT: media descriptors, root + bitmap chains EOC; 16-20 and 31-40 "allocated"
$fat = 2 * $bps   # FAT @ sector 2 (matches FATOffset in the boot sector)
W32 $bytes ($fat + 0)  0xFFFFFFF8
W32 $bytes ($fat + 4)  0xFFFFFFFF
W32 $bytes ($fat + 8)  0xFFFFFFFF   # cluster 2 = root dir
W32 $bytes ($fat + 12) 0xFFFFFFFF   # cluster 3 = bitmap
foreach ($c in 16..20) { W32 $bytes ($fat + 4 * $c) 0xFFFFFFFF }
foreach ($c in 31..40) { W32 $bytes ($fat + 4 * $c) 0xFFFFFFFF }

# root directory at cluster 2 (byte 2048): label, Allocation Bitmap, end
$root = $heapOff * $bps
$bytes[$root] = 0x83
[Array]::Copy([Text.Encoding]::ASCII.GetBytes('MINI'), 0, $bytes, $root + 1, 4)
$e1 = $root + 32
$bytes[$e1] = 0x81
W32 $bytes ($e1 + 0x14) 3    # bitmap FirstCluster
W64 $bytes ($e1 + 0x18) 8    # bitmap DataLength (8 bytes = 64 clusters)
$bytes[$root + 64] = 0x00    # end of directory

# bitmap at cluster 3 (byte 2048+4096), LSB-first: bit i of byte j <-> cluster 2+8j+i
# allocated = {2,3} {16-20} {31-40}; free = {4-15} {21-30} {41-65, above highest}
[Array]::Copy([byte[]](0x03, 0xC0, 0x07, 0xE0, 0x7F, 0x00, 0x00, 0x00), 0, $bytes, $root + $cs, 8)

[IO.File]::WriteAllBytes($img, $bytes)
Write-Host "built $img ($($bytes.Length) B)"

# run phase 1 against it
$out = Join-Path $dir 'phase1out'
& (Join-Path $repoRoot 'phase1_map.ps1') -Volume $img -OutDir $out

# verify
$fail = @()
$runs = Import-Csv (Join-Path $out 'free_runs.csv')
$bruns = Import-Csv (Join-Path $out 'byte_runs.csv')
$layout = Get-Content (Join-Path $out 'exfat_layout.json') -Raw | ConvertFrom-Json

if ($runs.Count -ne 2) { $fail += "expected 2 free runs, got $($runs.Count)" }
else {
    if ([int]$runs[0].first_cluster -ne 4  -or [int]$runs[0].last_cluster -ne 15 -or [int]$runs[0].cluster_count -ne 12) { $fail += "run1 wrong: $($runs[0])" }
    if ([int]$runs[1].first_cluster -ne 21 -or [int]$runs[1].last_cluster -ne 30 -or [int]$runs[1].cluster_count -ne 10) { $fail += "run2 wrong: $($runs[1])" }
}
if ([long]$layout.highest_allocated_cluster -ne 40) { $fail += "highest_allocated_cluster = $($layout.highest_allocated_cluster), expected 40" }
if ([long]$bruns[0].start_offset -ne ($heapOff * $bps + 2 * $cs) -or [long]$bruns[0].length -ne 12 * $cs) { $fail += "byte run1 wrong: $($bruns[0])" }
if ([long]$bruns[1].start_offset -ne ($heapOff * $bps + 19 * $cs) -or [long]$bruns[1].length -ne 10 * $cs) { $fail += "byte run2 wrong: $($bruns[1])" }

if ($fail.Count) { $fail | ForEach-Object { Write-Host "FAIL: $_" -ForegroundColor Red }; exit 1 }
Write-Host 'PHASE 1 SYNTHETIC TEST: PASS' -ForegroundColor Green
