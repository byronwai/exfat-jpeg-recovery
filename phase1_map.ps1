# phase1_map.ps1 - exFAT free-space mapper (read-only, PowerShell 5.1)
#
# Parses the volume geometry straight from the exFAT boot sector, walks the FAT
# and the root directory to locate the Allocation Bitmap (entry type 0x81), then
# derives the maximal contiguous FREE cluster runs from the bitmap bits and
# filters them below the highest allocated cluster (everything above that was
# never written and can only return zeros).
#
# Emits, next to this script by default:
#   exfat_layout.json - parsed geometry + run summary (ground truth for phases 2/3)
#   free_runs.csv     - first_cluster,last_cluster,cluster_count,size_bytes
#   byte_runs.csv     - start_offset,length  (absolute bytes on \\.\X: - carver input)
#
# Usage:  .\phase1_map.ps1 [-Volume 'E:'] [-OutDir $PSScriptRoot]
# Needs an elevated shell for the raw \\.\X: read.
#
# Gotchas baked in:
#   - FileStream.Length THROWS on a \\.\X: volume handle: never query it, take
#     extents from the boot sector and let short reads mark EOF.
#   - exFAT FAT entries are 4 B; 0xFFFFFFF7..0xFFFFFFFF are bad/reserved/EOC.
#     Those values do not fit Int32 (0xFFFFFFF7 parses as -9), so all cluster
#     arithmetic stays [uint32]/[long] and the threshold is built via ToUInt32.

param(
    [string]$Volume = 'E:',
    [string]$OutDir = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
$sw = [Diagnostics.Stopwatch]::StartNew()

# --- raw volume handle --------------------------------------------------------
# 'E:' style opens the raw \\.\E: device; anything else is treated as an image
# file path (lets the parser run against saved images / synthetic tests).
if ($Volume -match '^[A-Za-z]:$') { $volPath = '\\.\' + $Volume } else { $volPath = $Volume }
$fs = [System.IO.FileStream]::new($volPath,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::Read -bor [System.IO.FileShare]::Write,
    1MB,
    [System.IO.FileOptions]::SequentialScan)

function Read-Bytes([long]$Offset, [int]$Count) {
    [void]$fs.Seek($Offset, [System.IO.SeekOrigin]::Begin)
    $buf = New-Object byte[] $Count
    $done = 0
    while ($done -lt $Count) {
        $n = $fs.Read($buf, $done, $Count - $done)
        if ($n -le 0) { break }
        $done += $n
    }
    if ($done -lt $Count) { throw "short read at offset $Offset ($done of $Count bytes)" }
    , $buf
}

# --- boot sector / BPB --------------------------------------------------------
$boot = Read-Bytes 0 512
$sig = [Text.Encoding]::ASCII.GetString($boot, 3, 8)
if ($sig -ne 'EXFAT   ') { throw "volume $Volume is not exFAT (signature '$sig')" }

$bpsShift     = [int]$boot[0x6C]
$spcShift     = [int]$boot[0x6D]
$bps          = [long][math]::Pow(2, $bpsShift)                 # 512 B sector
$spc          = [long][math]::Pow(2, $spcShift)                 # sectors per cluster
$clusterSize  = $bps * $spc                                     # 256 KB on the incident volume
$fatOffSec    = [long][BitConverter]::ToUInt32($boot, 0x50)
$fatLenSec    = [long][BitConverter]::ToUInt32($boot, 0x54)
$heapOffSec   = [long][BitConverter]::ToUInt32($boot, 0x58)
$clusterCount = [long][BitConverter]::ToUInt32($boot, 0x5C)
$rootCluster  = [BitConverter]::ToUInt32($boot, 0x60)
$volLenSec    = [BitConverter]::ToUInt64($boot, 0x48)

$layout = [ordered]@{
    volume                      = $Volume
    bytes_per_sector            = $bps
    sectors_per_cluster         = $spc
    cluster_size_bytes          = $clusterSize
    fat_offset_sector           = $fatOffSec
    fat_length_sectors          = $fatLenSec
    fat_offset_bytes            = $fatOffSec * $bps
    fat_size_bytes              = $fatLenSec * $bps
    cluster_heap_offset_sector  = $heapOffSec
    cluster_heap_offset_bytes   = $heapOffSec * $bps
    cluster_count               = $clusterCount
    first_cluster               = 2
    last_cluster                = 1 + $clusterCount              # cluster numbers are 2..ClusterCount+1
    root_dir_cluster            = $rootCluster
    volume_sectors              = $volLenSec
    volume_bytes                = $volLenSec * $bps
}
Write-Host ("exFAT: sector {0} B, cluster {1} B ({2} sectors/cluster), FAT @ sector {3} ({4} sectors), heap @ sector {5}, {6} clusters, root @ cluster {7}" -f
    $bps, $clusterSize, $spc, $fatOffSec, $fatLenSec, $heapOffSec, $clusterCount, $rootCluster)

# --- FAT + cluster chains -----------------------------------------------------
$fat = Read-Bytes ($fatOffSec * $bps) ([int]($fatLenSec * $bps))
$CLUSTER_RESERVED = [Convert]::ToUInt32('FFFFFFF7', 16)          # bad/reserved/EOC threshold (uint32!)

function Get-ClusterChain([uint32]$First) {
    $chain = New-Object System.Collections.Generic.List[uint32]
    $c = $First
    while ($true) {
        if ($c -lt 2 -or $c -gt (1 + $clusterCount)) { throw "FAT chain out of range: cluster $c" }
        $chain.Add($c)
        $next = [BitConverter]::ToUInt32($fat, [int](4 * [long]$c))
        if ($next -ge $CLUSTER_RESERVED) { break }               # EOC / bad / reserved
        $c = $next
    }
    , $chain
}

function Read-ChainBytes($Chain) {
    $buf = New-Object byte[] ($Chain.Count * $clusterSize)
    $i = 0
    foreach ($c in $Chain) {
        $off = $layout.cluster_heap_offset_bytes + ([long]$c - 2) * $clusterSize
        $b = Read-Bytes $off $clusterSize
        [Array]::Copy($b, 0, $buf, $i * $clusterSize, $clusterSize)
        $i++
    }
    , $buf
}

# --- root directory: find the Allocation Bitmap (0x81) ------------------------
$rootBytes = Read-ChainBytes (Get-ClusterChain $rootCluster)
$bitmapMeta = $null
for ($e = 0; $e -lt $rootBytes.Length; $e += 32) {
    $type = $rootBytes[$e]
    if ($type -eq 0x00) { break }                                # end-of-directory marker
    if ($type -eq 0x81) {                                        # Allocation Bitmap entry
        $bitmapMeta = [pscustomobject]@{
            FirstCluster = [BitConverter]::ToUInt32($rootBytes, $e + 0x14)
            DataLength   = [BitConverter]::ToUInt64($rootBytes, $e + 0x18)
        }
        break
    }
}
if (-not $bitmapMeta) { throw 'no Allocation Bitmap (0x81) entry found in the root directory' }
Write-Host ("allocation bitmap: cluster {0}, {1} bits ({2} bytes)" -f $bitmapMeta.FirstCluster, ($bitmapMeta.DataLength * 8), $bitmapMeta.DataLength)

# --- read the bitmap through its FAT chain -------------------------------------
$bmBuf = Read-ChainBytes (Get-ClusterChain $bitmapMeta.FirstCluster)
if ($bitmapMeta.DataLength -gt $bmBuf.Length) { throw 'bitmap DataLength exceeds its FAT chain' }
$bitmap = New-Object byte[] ([int]$bitmapMeta.DataLength)
[Array]::Copy($bmBuf, $bitmap, [int]$bitmapMeta.DataLength)
$lastCluster = 1 + $clusterCount
if ($bitmap.Length * 8 -lt $clusterCount) { throw 'bitmap too small for cluster count' }

# --- highest allocated cluster: free space above it was NEVER written ----------
$highestAlloc = 0L
for ($j = $bitmap.Length - 1; $j -ge 0; $j--) {
    if ($bitmap[$j] -ne 0) {
        for ($bit = 7; $bit -ge 0; $bit--) {
            if ((($bitmap[$j] -shr $bit) -band 1) -eq 1) { $highestAlloc = 2 + 8 * $j + $bit; break }
        }
        break
    }
}
Write-Host ("highest allocated cluster: {0} (byte {1} = {2:F2} TB)" -f $highestAlloc,
    ($layout.cluster_heap_offset_bytes + ([long]$highestAlloc - 2) * $clusterSize),
    (($layout.cluster_heap_offset_bytes + ([long]$highestAlloc - 2) * $clusterSize) / 1TB))

# --- maximal contiguous free runs (byte-level scan with fast paths) ------------
# bit i of byte j <-> cluster 2 + 8j + i;  1 = allocated, 0 = free
$script:inRun = $false
$script:runStart = 0L
$runs = New-Object System.Collections.Generic.List[object]

function Close-Run([long]$EndCluster) {
    if ($script:inRun -and $script:runStart -lt $highestAlloc) {  # skip never-written space
        $len = $EndCluster - $script:runStart + 1
        $runs.Add([pscustomobject]@{
            first_cluster = $script:runStart
            last_cluster  = $EndCluster
            cluster_count = $len
            size_bytes    = [long]$len * $clusterSize
        })
    }
    $script:inRun = $false
}

for ($j = 0; $j -lt $bitmap.Length; $j++) {
    $b = [int]$bitmap[$j]
    $c0 = 2 + 8 * $j
    if ($b -eq 0x00) {                                           # 8 free clusters
        if (-not $script:inRun) { $script:inRun = $true; $script:runStart = $c0 }
    }
    elseif ($b -eq 0xFF) {                                       # 8 allocated clusters
        if ($script:inRun) { Close-Run ($c0 - 1) }
    }
    else {                                                       # mixed byte: per-bit
        for ($bit = 0; $bit -lt 8; $bit++) {
            if ((($b -shr $bit) -band 1) -eq 1) {
                if ($script:inRun) { Close-Run ($c0 + $bit - 1) }
            }
            elseif (-not $script:inRun) {
                $script:inRun = $true; $script:runStart = $c0 + $bit
            }
        }
    }
}
if ($script:inRun) { Close-Run $lastCluster }

# --- emit artifacts ------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$freeCsv = Join-Path $OutDir 'free_runs.csv'
$byteCsv = Join-Path $OutDir 'byte_runs.csv'
$jsonCsv = Join-Path $OutDir 'exfat_layout.json'

$runs | Export-Csv $freeCsv -NoTypeInformation
$byteRuns = foreach ($r in $runs) {
    [pscustomobject]@{
        start_offset = $layout.cluster_heap_offset_bytes + ([long]$r.first_cluster - 2) * $clusterSize
        length       = [long]$r.size_bytes
    }
}
$byteRuns | Export-Csv $byteCsv -NoTypeInformation

$layout['highest_allocated_cluster'] = $highestAlloc
$layout['free_run_count']            = $runs.Count
$layout['free_bytes_below_highest']  = ($runs | Measure-Object -Property size_bytes -Sum).Sum
$layout['free_runs']                 = $runs
$layout | ConvertTo-Json -Depth 4 | Set-Content -Path $jsonCsv -Encoding UTF8

$fs.Close()
$sw.Stop()

Write-Host ''
$runs | Format-Table first_cluster, last_cluster, cluster_count, @{n = 'GB'; e = { '{0:F2}' -f ($_.size_bytes / 1GB) } } -AutoSize
Write-Host ('{0} free runs below highest allocated cluster, {1:F2} GB total - wrote {2}, {3}, {4} ({5:F1} s)' -f
    $runs.Count, ($layout['free_bytes_below_highest'] / 1GB), (Split-Path $freeCsv -Leaf), (Split-Path $byteCsv -Leaf), (Split-Path $jsonCsv -Leaf), $sw.Elapsed.TotalSeconds)
