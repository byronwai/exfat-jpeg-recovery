// carver.cs - targeted, EXIF-gated JPEG carver for exFAT free space
//
// Counterpart to phase1_map.ps1. Consumes the byte_runs.csv that phase1 emits
// (absolute byte offset + length of every contiguous free run on the volume,
// already filtered below the highest allocated cluster) and streams ONLY those
// runs from the raw volume handle - never the terabytes of never-written space,
// never the clusters owned by the 29.5k live photos.
//
// Per FF D8 FF candidate:
//   1. re-reads up to a 64 MB window at that offset (sector-aligned reads),
//   2. validates the marker structure - must reach SOS through well-formed
//      APPn/DQT/SOF... segments, so stray FF D8 FF bytes die here,
//   3. parses DateTimeOriginal (tag 0x9003) inline from the APP1 "Exif" TIFF
//      IFD0 -> Exif-IFD (0x8769),
//   4. finds the TRUE end of file: after SOS it honors FF 00 byte-stuffing and
//      RST markers (FF D0-D7) until FF D9, so the EOI of Canon's embedded EXIF
//      thumbnail cannot truncate the file,
//   5. saves ONLY frames whose capture date falls in the keep window
//      (match\ = keep date, near\ = adjacent days); everything else is counted
//      and discarded, so the output is not buried under foreign shoots.
// A skip-ahead cursor resumes scanning past each validated JPEG (saved or
// discarded), so embedded thumbnails cannot be carved twice. A frame cut at a
// free-run boundary is still saved, flagged _TRUNC.
//
// Build (phase3_carve.ps1 does this):
//   C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /out:carver.exe carver.cs
//   (Framework csc = C# 5 only - no string interpolation / local functions.)
//
// Run:
//   carver.exe <volume-or-image> <byte_runs.csv> <outdir> <keepDate> [nearDate ...]
//   e.g. carver.exe \\.\E: byte_runs.csv found 2026:09:06 2026:09:05 2026:09:07 2026:09:08
//
// Gotchas baked in (see write-up):
//   - NEVER query FileStream.Length on a \\.\X: volume handle (it throws);
//     extents come from byte_runs.csv and EOF is absorbed by short reads.
//   - volume reads start at a 512 B-aligned offset so raw handles accept them.

using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

static class Carver
{
    const int BLOCK  = 8 * 1024 * 1024;   // 8 MB streaming block
    const int CARRY  = 64 * 1024;         // 64 KB carry-over across block edges
    const int WINDOW = 64 * 1024 * 1024;  // 64 MB max per-candidate window

    static FileStream vol;
    static string matchDir, nearDir;
    static StreamWriter manifest;
    static string keepDate;
    static List<string> nearDates = new List<string>();

    // candidate window: loaded once per SOI, sector-aligned base
    static byte[] win = new byte[WINDOW + 512];
    static long winBase, winEnd;          // valid bytes are [winBase, winEnd)

    static Dictionary<string, int> stats = new Dictionary<string, int>();
    static long savedBytes;

    static int Main(string[] args)
    {
        if (args.Length < 4)
        {
            Console.Error.WriteLine("usage: carver <volume|image> <byte_runs.csv> <outdir> <keepDate> [nearDate ...]");
            Console.Error.WriteLine("example: carver \\\\.\\E: byte_runs.csv found 2026:09:06 2026:09:05 2026:09:07 2026:09:08");
            return 2;
        }
        string volume = args[0], runsPath = args[1], outdir = args[2];
        keepDate = args[3];
        for (int i = 4; i < args.Length; i++) nearDates.Add(args[i]);

        matchDir = Path.Combine(outdir, "match");
        nearDir  = Path.Combine(outdir, "near");
        Directory.CreateDirectory(matchDir);
        Directory.CreateDirectory(nearDir);

        string[] keys = new string[] { "candidates", "valid", "saved_match", "saved_near",
                                       "truncated", "discarded_date", "no_exif", "oversize", "rejected" };
        foreach (string k in keys) stats[k] = 0;

        // FileStream.Length throws on a \\.\X: volume handle - never touch it.
        vol = new FileStream(volume, FileMode.Open, FileAccess.Read,
                             FileShare.Read | FileShare.Write, 1024 * 1024,
                             FileOptions.SequentialScan);

        string manifestPath = Path.Combine(outdir, "manifest.csv");
        bool fresh = !File.Exists(manifestPath);
        manifest = new StreamWriter(manifestPath, true, Encoding.UTF8);
        if (fresh) manifest.WriteLine("path,exif,size,truncated,offset");

        List<long[]> runs = new List<long[]>();
        foreach (string line in File.ReadAllLines(runsPath))
        {
            string[] t = line.Split(',');
            if (t.Length < 2) continue;
            long s, n;
            if (!long.TryParse(t[0].Trim(), out s) || !long.TryParse(t[1].Trim(), out n)) continue; // header/blank
            if (n > 0) runs.Add(new long[] { s, n });
        }
        Console.WriteLine("carver: {0} runs from {1}, keep={2} near=[{3}]", runs.Count, runsPath, keepDate, string.Join(" ", nearDates.ToArray()));

        DateTime t0 = DateTime.UtcNow;
        foreach (long[] r in runs) CarveRun(r[0], r[0] + r[1]);
        manifest.Close();

        Console.WriteLine("done in {0:F0}s: candidates={1} valid={2} | match={3} near={4} truncated={5} | discarded_date={6} no_exif={7} oversize={8} rejected={9} | wrote {10:F1} MB",
            (DateTime.UtcNow - t0).TotalSeconds, stats["candidates"], stats["valid"],
            stats["saved_match"], stats["saved_near"], stats["truncated"],
            stats["discarded_date"], stats["no_exif"], stats["oversize"], stats["rejected"],
            savedBytes / 1048576.0);
        return 0;
    }

    // ---- streaming scan of one free run -------------------------------------
    static void CarveRun(long runStart, long runEnd)
    {
        Console.WriteLine("run {0:x12}-{1:x12} ({2:F2} GB)", runStart, runEnd, (runEnd - runStart) / 1073741824.0);
        long skipUntil = runStart;                    // skip-ahead cursor
        byte[] tail = new byte[CARRY];
        int tailLen = 0;
        for (long pos = runStart; pos < runEnd; pos += BLOCK)
        {
            int want = (int)Math.Min((long)BLOCK, runEnd - pos);
            byte[] blk = new byte[want];
            int got = ReadAligned(pos, blk, want);
            if (got <= 0) break;

            byte[] buf; long baseOff;
            if (tailLen > 0)
            {
                buf = new byte[tailLen + got];
                Buffer.BlockCopy(tail, 0, buf, 0, tailLen);
                Buffer.BlockCopy(blk, 0, buf, tailLen, got);
                baseOff = pos - tailLen;
            }
            else { buf = blk; baseOff = pos; }

            ScanBuffer(buf, baseOff, runEnd, ref skipUntil);

            int keep = Math.Min(CARRY, buf.Length);   // carry tail into next block
            Buffer.BlockCopy(buf, buf.Length - keep, tail, 0, keep);
            tailLen = keep;
            if (got < want) break;                    // volume EOF
        }
    }

    static void ScanBuffer(byte[] buf, long baseOff, long runEnd, ref long skipUntil)
    {
        int n = buf.Length;
        for (int i = 0; i + 2 < n; i++)
        {
            if (buf[i] != 0xFF || buf[i + 1] != 0xD8 || buf[i + 2] != 0xFF) continue;
            long abs = baseOff + i;
            if (abs < skipUntil) continue;            // inside an already-validated file
            Process(abs, runEnd, ref skipUntil);
        }
    }

    // ---- per-candidate pipeline ---------------------------------------------
    static void Process(long o, long runEnd, ref long skipUntil)
    {
        stats["candidates"]++;
        LoadWindow(o, runEnd);
        long limit = winEnd;

        long sos = ValidateHeader(o);
        if (sos < 0) { stats["rejected"]++; return; }  // not a well-formed JPEG header
        stats["valid"]++;

        string exif = ExtractDateTimeOriginal(o);

        int sosLen = (W(sos + 2) << 8) | W(sos + 3);
        long scanStart = sos + 2 + sosLen;
        if (scanStart > limit) scanStart = limit;

        long eoi = FindEOI(scanStart, limit);
        bool trunc = false; long end;
        if (eoi >= 0) end = eoi;
        else if (limit - o >= WINDOW) { stats["oversize"]++; return; } // no EOI in 64 MB: false positive
        else { trunc = true; end = limit; }           // cut at free-run boundary

        // EXIF date gate: match\, near\, or counted-and-discarded
        string cls = null;
        if (exif != null && LooksLikeDate(exif))
        {
            if (exif.StartsWith(keepDate)) cls = "match";
            else foreach (string nd in nearDates) if (exif.StartsWith(nd)) { cls = "near"; break; }
        }
        if (cls == null)
        {
            if (exif == null || !LooksLikeDate(exif)) stats["no_exif"]++; else stats["discarded_date"]++;
            skipUntil = end;                          // its embedded thumbnail is noise too
            return;
        }

        string safe = exif.Replace(":", "").Replace(" ", "_");
        string name = "jpg_" + o.ToString("x12") + "_" + safe + (trunc ? "_TRUNC" : "") + ".jpg";
        string path = Path.Combine(cls == "match" ? matchDir : nearDir, name);
        using (FileStream f = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20, FileOptions.SequentialScan))
            f.Write(win, (int)(o - winBase), (int)(end - o));

        manifest.WriteLine("{0},{1},{2},{3},{4:x}", path, exif, end - o, trunc ? 1 : 0, o);
        manifest.Flush();
        stats[cls == "match" ? "saved_match" : "saved_near"]++;
        if (trunc) stats["truncated"]++;
        savedBytes += end - o;
        skipUntil = end;                              // resume scanning past this file
        Console.WriteLine("  {0}  {1}  {2} bytes{3}", name, exif, end - o, trunc ? "  TRUNC" : "");
    }

    // ---- JPEG structure ------------------------------------------------------
    // Returns absolute index of the SOS marker, or -1 if the header is not
    // well-formed (every length-bearing segment must carry len >= 2 and stay
    // in-window; EOI before SOS is fatal).
    static long ValidateHeader(long soi)
    {
        long i = soi + 2;
        while (InWin(i, 4))
        {
            if (W(i) != 0xFF) return -1;
            int m = W(i + 1);
            if (m == 0xFF) { i += 1; continue; }               // fill bytes
            if (m == 0x01 || m == 0xD8) { i += 2; continue; }  // standalone, no length
            if (m >= 0xD0 && m <= 0xD7) { i += 2; continue; }  // RSTn
            if (m == 0xD9) return -1;                          // EOI before SOS
            if (m == 0xDA) return i;                           // reached SOS: header valid
            if (!InWin(i + 2, 2)) return -1;
            int len = (W(i + 2) << 8) | W(i + 3);
            if (len < 2) return -1;
            i += 2 + len;
        }
        return -1;
    }

    static string ExtractDateTimeOriginal(long soi)
    {
        long i = soi + 2;
        while (InWin(i, 4))
        {
            if (W(i) != 0xFF) return null;
            int m = W(i + 1);
            if (m == 0xFF) { i += 1; continue; }
            if (m == 0xDA || m == 0xD9) return null;           // date must live in the header
            if (m == 0x01 || m == 0xD8 || (m >= 0xD0 && m <= 0xD7)) { i += 2; continue; }
            if (!InWin(i + 2, 2)) return null;
            int len = (W(i + 2) << 8) | W(i + 3);
            if (len < 2) return null;
            if (m == 0xE1 && len >= 10 && InWin(i + 4, 6)      // APP1 "Exif\0\0"
                && W(i + 4) == 0x45 && W(i + 5) == 0x78 && W(i + 6) == 0x69 && W(i + 7) == 0x66
                && W(i + 8) == 0 && W(i + 9) == 0)
            {
                string d = ParseTiffDate(i + 10, i + 2 + len);
                if (d != null) return d;
            }
            i += 2 + len;
        }
        return null;
    }

    static string ParseTiffDate(long t, long tiffEnd)
    {
        if (!InWin(t, 8)) return null;
        bool le = W(t) == 0x49 && W(t + 1) == 0x49;            // "II"
        bool be = W(t) == 0x4D && W(t + 1) == 0x4D;            // "MM"
        if (!le && !be) return null;
        if (RU16(t + 2, le) != 42) return null;

        long ifd0 = t + RU32(t + 4, le);
        long exifIfd = FindSubIfd(t, ifd0, 0x8769, le, tiffEnd);
        string d = null;
        if (exifIfd >= 0) d = FindAsciiTag(t, exifIfd, 0x9003, le, tiffEnd);
        if (d == null) d = FindAsciiTag(t, ifd0, 0x9003, le, tiffEnd);  // some writers put it in IFD0
        return d;
    }

    static long FindSubIfd(long t, long ifdOff, int tag, bool le, long tiffEnd)
    {
        if (!InWin(ifdOff, 2) || ifdOff + 2 > tiffEnd) return -1;
        int n = RU16(ifdOff, le);
        if (n > 512) return -1;                                // sanity cap
        for (int e = 0; e < n; e++)
        {
            long ent = ifdOff + 2 + 12 * e;
            if (!InWin(ent, 12) || ent + 12 > tiffEnd) return -1;
            if (RU16(ent, le) == tag) return t + RU32(ent + 8, le);
        }
        return -1;
    }

    static string FindAsciiTag(long t, long ifdOff, int tag, bool le, long tiffEnd)
    {
        if (!InWin(ifdOff, 2)) return null;
        int n = RU16(ifdOff, le);
        if (n > 512) return null;
        for (int e = 0; e < n; e++)
        {
            long ent = ifdOff + 2 + 12 * e;
            if (!InWin(ent, 12) || ent + 12 > tiffEnd) return null;
            if (RU16(ent, le) != tag) continue;
            int cnt = (int)RU32(ent + 4, le);
            if (cnt < 19) return null;                         // "yyyy:MM:dd HH:mm:ss"
            long vo = cnt > 4 ? t + RU32(ent + 8, le) : ent + 8;
            if (!InWin(vo, 19)) return null;
            byte[] s = new byte[19];
            for (int k = 0; k < 19; k++) s[k] = W(vo + k);
            return Encoding.ASCII.GetString(s);
        }
        return null;
    }

    // Entropy-coded scan: FF 00 is a stuffed data byte, FF D0-D7 are RST
    // markers - only FF D9 ends the file. This is what keeps the carver from
    // truncating at the embedded EXIF thumbnail's EOI.
    static long FindEOI(long from, long limit)
    {
        bool ff = false;
        for (long i = from; i < limit; i++)
        {
            byte c = W(i);
            if (ff)
            {
                if (c == 0x00) { ff = false; continue; }
                if (c >= 0xD0 && c <= 0xD7) { ff = false; continue; }
                if (c == 0xD9) return i + 1;                   // true end (exclusive)
                ff = false; continue;
            }
            ff = (c == 0xFF);
        }
        return -1;
    }

    static bool LooksLikeDate(string s)
    {
        if (s == null || s.Length != 19) return false;
        for (int i = 0; i < 19; i++)
        {
            char c = s[i];
            bool ok = (c >= '0' && c <= '9')
                   || ((i == 4 || i == 7 || i == 13 || i == 16) && c == ':')
                   || (i == 10 && c == ' ');
            if (!ok) return false;
        }
        return true;
    }

    // ---- raw I/O --------------------------------------------------------------
    static byte W(long abs) { return win[abs - winBase]; }
    static bool InWin(long abs, int n) { return abs >= winBase && abs + n <= winEnd; }

    static ushort RU16(long o, bool le)
    {
        return (ushort)(le ? W(o) | (W(o + 1) << 8) : (W(o) << 8) | W(o + 1));
    }
    static uint RU32(long o, bool le)
    {
        if (le) return (uint)(W(o) | (W(o + 1) << 8) | (W(o + 2) << 16) | (W(o + 3) << 24));
        return (uint)((W(o) << 24) | (W(o + 1) << 16) | (W(o + 2) << 8) | W(o + 3));
    }

    static int ReadAligned(long off, byte[] buf, int count)
    {
        vol.Seek(off, SeekOrigin.Begin);
        int done = 0;
        while (done < count)
        {
            int n = vol.Read(buf, done, count - done);
            if (n <= 0) break;
            done += n;
        }
        return done;
    }

    // Load a window covering [off, min(maxEnd, off+WINDOW)) reading from a
    // 512 B-aligned start so raw volume handles accept it. Short reads (volume
    // EOF) simply shrink the window.
    static void LoadWindow(long off, long maxEnd)
    {
        long start = off & ~511L;
        long end = Math.Min(maxEnd, off + WINDOW);
        if (end <= start) { winBase = off; winEnd = off; return; }
        long len = end - start;
        if ((len & 511) != 0) len += 512 - (len & 511);
        if (len > win.Length) len = win.Length;
        vol.Seek(start, SeekOrigin.Begin);
        long done = 0;
        while (done < len)
        {
            int n = vol.Read(win, (int)done, (int)(len - done));
            if (n <= 0) break;
            done += n;
        }
        winBase = start;
        winEnd = start + done;
    }
}
