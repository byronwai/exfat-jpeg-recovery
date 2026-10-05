# exFAT Targeted JPEG Recovery

![Platform](https://img.shields.io/badge/platform-Windows-blue)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE)
![C#](https://img.shields.io/badge/C%23-.NET%20Framework-68217A)
![Dependencies](https://img.shields.io/badge/dependencies-none-success)

A targeted file carver that recovers a **specific photo shoot** from the free
space of an exFAT volume after it has been overwritten — by parsing the
filesystem's allocation bitmap to locate where deleted data can still exist,
then carving only those regions with an EXIF-date-gated scanner.

📖 Full incident write-up: **[English](WRITEUP.md)** | **[繁體中文](WRITEUP.zh-TW.md)**

## Features

- ✅ **Recovers *this shoot*, not every JPEG on the disk** — only frames whose
  EXIF `DateTimeOriginal` falls inside the keep window are saved; everything
  else is counted and discarded.
- ✅ **Structure-aware EOF detection** — the entropy scan honors `FF 00`
  byte-stuffing and `FF D0–D7` restart markers up to the *true* `FF D9`, so
  embedded EXIF thumbnails (which carry their own EOI) cannot truncate files.
- ✅ **Surgical targeting** — carves only the free-cluster runs mapped from
  the exFAT allocation bitmap; live files and never-written space are skipped.
- ✅ **Headless & scriptable** — single self-contained EXE (no UAC manifest),
  deterministic output filenames, crash-safe append+flush manifest.
- ✅ **Tested before it touches real media** — positive-control drill and a
  synthetic exFAT image self-test are built in.

## Quick Start

From an **elevated** PowerShell (raw `\\.\X:` volume reads):

```powershell
# 1. Map the free space (defaults: E:, output beside the script)
.\phase1_map.ps1 -Volume E:

# 2. (optional, recommended) sanity-check the carver on synthetic data
.\phase2_control.ps1

# 3. Compile and carve
.\phase3_carve.ps1 -Volume E: -KeepDate '2026:09:06' -NearDates '2026:09:05','2026:09:07','2026:09:08'
```

Recovered frames land in `found\match\` (keep date) and `found\near\`
(adjacent dates), indexed by `found\manifest.csv`.

## How It Works

```text
phase1_map.ps1                carver.exe (carver.cs)                    found\
 boot sector ----\            8 MB blocks + 64 KB carry  ---->  match\  (keep date)
 FAT + root dir   --> byte_runs.csv  per-candidate 64 MB      near\   (adjacent days)
 allocation       |           window re-read (aligned)        manifest.csv
 bitmap ---------'           marker walk -> SOS valid?
                             EXIF 0x9003 date gate
                             stuffed-byte EOI scan
```

| Stage | What it does |
|---|---|
| `phase1_map.ps1` | Parses exFAT geometry from the boot sector, walks the FAT and root directory to the Allocation Bitmap (entry `0x81`), and emits the maximal contiguous free-cluster runs (`free_runs.csv`, `byte_runs.csv`, `exfat_layout.json`). |
| `phase2_control.ps1` | Carves a synthetic container (known-date JPEG + decoy + truncated copy) and byte-compares the result — a positive control before real media. |
| `phase3_carve.ps1` | Compiles `carver.cs` with the stock Windows `csc` and runs it over the run map. |
| `carver.cs` | Streams each free run in 8 MB blocks (64 KB carry for boundary-spanning headers), validates every `FF D8 FF` candidate by marker-walk to SOS, reads `DateTimeOriginal` inline from the APP1 TIFF (`0x8769` → `0x9003`), finds the true EOI, saves gated frames as `jpg_<hex-offset>_<EXIF>_TRUNC?.jpg`, and resumes scanning past each validated JPEG. |

## Requirements

- Windows with PowerShell 5.1 and .NET Framework 4.x (`csc.exe` ships with Windows)
- An elevated shell for raw volume access
- No third-party dependencies

The carver also runs standalone against a saved image file in place of a
live volume:

```text
carver.exe <volume-or-image> <byte_runs.csv> <outdir> <keepDate> [nearDate ...]
```

## Limitations

- Overwritten sectors are unrecoverable — this tool finds everything that
  *still exists* in free space, nothing more.
- Fragmented frames may reassemble only partially; frames cut at a free-run
  boundary are saved with a `_TRUNC` suffix.

## Project Structure

```text
.
├── carver.cs                  # targeted, EXIF-gated JPEG carver (C# 5)
├── phase1_map.ps1             # exFAT boot-sector/FAT/bitmap parser → free-run map
├── phase2_control.ps1         # positive-control drill for the carver
├── phase3_carve.ps1           # compile + run the carver against the run map
├── selftest/
│   └── make_mini_exfat.ps1    # phase 1 self-test on a synthetic exFAT image
├── WRITEUP.md                 # lessons-learned technical write-up (English)
└── WRITEUP.zh-TW.md           # lessons-learned technical write-up (繁體中文)
```

Build artifacts (`carver.exe`) and per-run outputs (`found/`,
`byte_runs.csv`, …) are generated at run time and gitignored.
