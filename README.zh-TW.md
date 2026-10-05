# exFAT 目標式 JPEG 資料復原

![Platform](https://img.shields.io/badge/platform-Windows-blue)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE)
![C#](https://img.shields.io/badge/C%23-.NET%20Framework-68217A)
![Dependencies](https://img.shields.io/badge/dependencies-none-success)

**語言：** [English](README.md) · [繁體中文](README.zh-TW.md)

一支目標式檔案雕復器：從被覆蓋的 exFAT 磁碟區空閒空間中找回**特定一場拍攝**
——剖析檔案系統的配置位元圖，定位已刪除資料仍可能存在的位置，再以帶 EXIF
日期閘門的掃描器*只*雕復該範圍。

📖 完整事件報告：**[繁體中文](WRITEUP.zh-TW.md)** | **[English](WRITEUP.md)**

## 功能特色

- ✅ **救回的是*這一場拍攝*，而非磁碟上所有 JPEG**——僅存檔 EXIF
  `DateTimeOriginal` 落在保留視窗內的影格；其餘一律計數後丟棄。
- ✅ **結構感知的檔尾判定**——熵掃描尊重 `FF 00` 位元組填充與 `FF D0–D7`
  重啟標記，直至*真正的* `FF D9`，內嵌 EXIF 縮圖自帶的 EOI 無法截斷檔案。
- ✅ **外科手術式定位**——只雕復由 exFAT 配置位元圖映射出的空閒叢集段；
  現存檔案與從未寫入的空間一律略過。
- ✅ **無頭、可腳本化**——單一自足 EXE（無 UAC 資訊清單）、確定性輸出檔名、
  可撐過當機的 append+flush 清單。
- ✅ **碰真實媒體前先測試**——內建正控制組演練與合成 exFAT 映像自測。

## 快速開始

以**系統管理員** PowerShell 執行（原始 `\\.\X:` 磁碟區讀取）：

```powershell
# 1. 映射空閒空間（預設 E:，輸出在腳本旁）
.\phase1_map.ps1 -Volume E:

# 2.（選配，建議）先在合成資料上驗證雕復器
.\phase2_control.ps1

# 3. 編譯並雕復
.\phase3_carve.ps1 -Volume E: -KeepDate '2026:09:06' -NearDates '2026:09:05','2026:09:07','2026:09:08'
```

復原的影格落在 `found\match\`（保留日）與 `found\near\`（相鄰日），由
`found\manifest.csv` 索引。

## 運作原理

```text
phase1_map.ps1                carver.exe (carver.cs)                    found\
 boot sector ----\            8 MB blocks + 64 KB carry  ---->  match\  (keep date)
 FAT + root dir   --> byte_runs.csv  per-candidate 64 MB      near\   (adjacent days)
 allocation       |           window re-read (aligned)        manifest.csv
 bitmap ---------'           marker walk -> SOS valid?
                             EXIF 0x9003 date gate
                             stuffed-byte EOI scan
```

| 階段 | 說明 |
|---|---|
| `phase1_map.ps1` | 從啟動磁區剖析 exFAT 幾何參數，沿 FAT 與根目錄找到配置位元圖（項目 `0x81`），輸出最大連續空閒叢集段（`free_runs.csv`、`byte_runs.csv`、`exfat_layout.json`）。 |
| `phase2_control.ps1` | 雕復一個合成容器（已知日期 JPEG + 誘餌 + 截斷副本）並逐位元組比對——上真實媒體前的正控制組。 |
| `phase3_carve.ps1` | 以 Windows 內建 `csc` 編譯 `carver.cs`，並對映射結果執行。 |
| `carver.cs` | 以 8 MB 區塊串流每個空閒叢集段（64 KB 尾巴涵蓋跨邊界檔頭），對每個 `FF D8 FF` 候選走訪標記結構驗證至 SOS、就地從 APP1 TIFF 讀取 `DateTimeOriginal`（`0x8769` → `0x9003`）、找出真正的 EOI、以日期閘門存檔為 `jpg_<hex-offset>_<EXIF>_TRUNC?.jpg`，並跳過每個已驗證 JPEG 之後繼續掃描。 |

## 需求

- Windows、PowerShell 5.1、.NET Framework 4.x（`csc.exe` Windows 內建）
- 原始磁碟區存取需系統管理員 shell
- 無第三方相依

雕復器也可獨立對付磁碟映像檔以取代活的磁碟區：

```text
carver.exe <volume-or-image> <byte_runs.csv> <outdir> <keepDate> [nearDate ...]
```

## 限制

- 已被覆蓋的磁區無法復原——本工具找回的是空閒空間中*仍存在的一切*，不多也不少。
- 碎片化影格可能僅能部分重組；在空閒叢集段邊界被切斷的影格以 `_TRUNC` 尾碼存檔。

## 專案結構

```text
.
├── carver.cs                  # 目標式、EXIF 閘門的 JPEG 雕復器（C# 5）
├── phase1_map.ps1             # exFAT 啟動磁區／FAT／位元圖剖析器 → 空閒叢集段映射
├── phase2_control.ps1         # 雕復器正控制組
├── phase3_carve.ps1           # 編譯並對映射結果執行雕復器
├── selftest/
│   └── make_mini_exfat.ps1    # 以合成 exFAT 映像自測第一階段
├── WRITEUP.md                 # 經驗教訓技術報告（英文）
└── WRITEUP.zh-TW.md           # 經驗教訓技術報告（繁體中文）
```

建置產物（`carver.exe`）與每次執行的輸出（`found/`、`byte_runs.csv`…）
於執行時產生並被 gitignore。
