#!/usr/bin/env python3
"""
一次跑完"歌词模块到底能不能修"的离线取证。

它回答四个问题（每个问题对应报告里的一节）：

  [A] `has_lyrics` 这个键在二进制里和什么在一起，`enable_has_lyrics_check_bypass`
      周围还有哪些 flag —— 用来判断"改 flag 让它每首歌都建模块"这条路通不通。
  [B] 歌词相关模块（Lyrics_CardElementImpl / Lyrics_NPVElementsKitImpl /
      Lyrics_CoreInternalImpl / Lyrics_RepositoryImpl）的方法名候选，
      以及含 availability / shouldShow / hasLyrics 一类词的"判定点"候选。
  [C] **最关键**：歌词请求还走不走过 EeveeSpotify 钩的那条 HTTP 路径
      （`color-lyrics/v2`）。如果 9.1.x 改成了别的方式（esperanto / gRPC /
      本地离线 store），那"在响应里塞我们的歌词"这条路就是空的 ——
      这能一次性解释"有些歌根本没模块"。
  [D] Lyrics_OfflineImpl 的接口线索（本地有词 → 不请求也能建模块）。

用法
====
    python audit_lyrics_gate.py
    python audit_lyrics_gate.py --ipa "C:\\dsh\\ipa\\Spotify- Music and Podcasts_9.1.86_decrypted.ipa"
    python audit_lyrics_gate.py --baseline "C:\\dsh\\ipa\\EeveeSpotify-9.1.0.ipa"

不给 --ipa 时会自动在常见位置找 `*decrypted*.ipa`。
"""

import argparse
import os
import re
import sys
import zipfile

# ── Mach-O ────────────────────────────────────────────────────────────────
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA
FAT_MAGIC_64 = 0xCAFEBABF
FAT_CIGAM_64 = 0xBFBAFECA
LC_SEGMENT_64 = 0x19

SECTIONS_OF_INTEREST = (
    "__objc_classname", "__objc_methname", "__cstring",
    "__swift5_reflstr", "__swift5_typeref",
)

# [C] 走不走 HTTP 的证据词
TRANSPORT_WORDS = (
    "color-lyrics", "colorlyrics", "ColorLyrics",
    "lyrics/v2", "esperanto", "spclient", "/lyrics",
)

GATE_WORDS = (
    "availability", "available", "shouldshow", "shouldhide", "canshow",
    "haslyrics", "has_lyrics", "shoulddisplay", "shouldrender",
    "makeelement", "elementfactory", "showcard", "hidecard",
)

MODULES = (
    "Lyrics_CardElementImpl", "Lyrics_NPVElementsKitImpl", "Lyrics_CoreInternalImpl",
    "Lyrics_RepositoryImpl", "Lyrics_OfflineImpl", "Lyrics_NPVCommunicatorImpl",
    "Lyrics_RemoteDataSourceImpl",
)


def u32(b, o, big=False):
    return int.from_bytes(b[o:o + 4], "big" if big else "little")


def u64(b, o, big=False):
    return int.from_bytes(b[o:o + 8], "big" if big else "little")


def macho_slice(blob):
    le, be = u32(blob, 0), u32(blob, 0, big=True)
    if le in (MH_MAGIC_64, 0xCFFAEDFE):
        return 0, len(blob)
    if be in (FAT_MAGIC, FAT_MAGIC_64) or le in (FAT_MAGIC, FAT_MAGIC_64):
        big = be in (FAT_MAGIC, FAT_MAGIC_64)
        n = u32(blob, 4, big=big)
        entry = 32 if (be == FAT_MAGIC_64 or le == FAT_MAGIC_64) else 20
        fb = None
        for i in range(n):
            base = 8 + i * entry
            cpu = u32(blob, base, big=big)
            off = u32(blob, base + 8, big=big)
            size = u32(blob, base + 12, big=big)
            if cpu == 0x0100000C:
                return off, size
            if fb is None:
                fb = (off, size)
        if fb:
            return fb
    raise SystemExit("不是可识别的 Mach-O（magic=0x%08X）—— IPA 解密了吗？" % le)


def parse_sections(sl):
    if u32(sl, 0) != MH_MAGIC_64:
        raise SystemExit("切片不是 64 位 Mach-O")
    ncmds, off, found = u32(sl, 16), 32, {}
    for _ in range(ncmds):
        if off + 8 > len(sl):
            break
        cmd, cmdsize = u32(sl, off), u32(sl, off + 4)
        if cmdsize <= 0:
            break
        if cmd == LC_SEGMENT_64:
            nsects, so = u32(sl, off + 64), off + 72
            for _ in range(nsects):
                if so + 80 > len(sl):
                    break
                name = sl[so:so + 16].split(b"\0")[0].decode("ascii", "replace")
                size, foff = u64(sl, so + 40), u32(sl, so + 48)
                if size and foff:
                    found.setdefault(name, (foff, size))
                so += 80
        off += cmdsize
    return found


def load_strings(ipa, entry=None):
    with zipfile.ZipFile(ipa) as zf:
        names = zf.namelist()
        if entry is None:
            cands = [n for n in names if n.startswith("Payload/")
                     and n.count("/") == 2 and not n.endswith("/")]
            if not cands:
                raise SystemExit("IPA 里找不到主二进制")
            entry = next((n for n in cands
                          if n.split("/")[-1] == n.split("/")[1][:-4]), cands[0])
        blob = zf.read(entry)
    off, size = macho_slice(blob)
    sl = blob[off:off + size]
    secs = parse_sections(sl)
    out = []
    for name in SECTIONS_OF_INTEREST:
        if name in secs:
            fo, sz = secs[name]
            out.extend(s.decode("utf-8", "replace") for s in sl[fo:fo + sz].split(b"\0") if s)
    return out, entry, secs


def run(ipa, emit, baseline=False):
    tag = "基线 9.1.0" if baseline else "目标 9.1.86"
    emit("# ===== %s : %s" % (tag, ipa))
    strings, entry, secs = load_strings(ipa)
    emit("# 条目 %s / 字符串 %d 条 / 节 %s"
         % (entry, len(strings), ", ".join(sorted(secs)) or "(无)"))
    emit()

    # [A] has_lyrics 与 flag
    emit("[A] has_lyrics 键与歌词相关 flag")
    for s in sorted({x for x in strings if "has_lyrics" in x or "hasLyrics" in x})[:30]:
        emit("    key  %s" % s)
    flags = sorted({x for x in strings
                    if re.fullmatch(r"(?:enable|ios|s2s|catalog)_[a-z0-9_]*lyric[a-z0-9_]*", x)})
    emit("    flags total=%d" % len(flags))
    for f in flags:
        emit("      %s" % f)
    emit()

    # [C] 传输路径（最关键）
    emit("[C] 歌词请求走不走 HTTP / color-lyrics 路径")
    for w in TRANSPORT_WORDS:
        hits = sorted({x for x in strings if w in x})[:6]
        emit("    %-14s 命中 %d" % (w, len(hits)))
        for h in hits:
            emit("        %s" % h[:160])
    emit()

    # [B] 模块符号与判定点
    emit("[B] 模块方法名与判定点候选")
    for mod in MODULES:
        rel = sorted({x for x in strings if mod in x})
        emit("    ── %s : %d 条" % (mod, len(rel)))
        for r in rel[:40]:
            emit("        %s" % r[:160])
    emit()
    emit("    ── 含 gate 关键词的串（跨全表） ──")
    gates = sorted({x for x in strings
                    if any(w in x.lower() for w in GATE_WORDS) and len(x) < 160})
    emit("    命中 %d 条" % len(gates))
    for g in gates[:150]:
        emit("        %s" % g)
    emit()

    # [D] 离线存储
    emit("[D] Lyrics_Offline 接口线索")
    for s in sorted({x for x in strings
                     if any(k in x for k in ("LyricsOffline", "lyrics_offline", "PlaybackId"))})[:60]:
        emit("    %s" % s[:160])


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ipa", default=None)
    ap.add_argument("--baseline", default=None)
    ap.add_argument("--out", default="lyrics_gate_audit.txt")
    args = ap.parse_args()

    if not args.ipa:
        for d in (r"C:\dsh\ipa", os.path.expanduser("~/Downloads"), os.getcwd()):
            if os.path.isdir(d):
                for fn in sorted(os.listdir(d)):
                    if fn.lower().endswith(".ipa") and "decrypted" in fn.lower():
                        args.ipa = os.path.join(d, fn)
                        break
            if args.ipa:
                break
    if not args.ipa:
        raise SystemExit("没找到解密 IPA，请用 --ipa 传入")

    lines = []

    def emit(t=""):
        print(t)
        lines.append(t)

    run(args.ipa, emit, baseline=False)
    if args.baseline:
        emit()
        run(args.baseline, emit, baseline=True)

    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    print("\n# 报告写入 %s" % args.out)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception:
        import traceback
        traceback.print_exc()
        sys.exit(1)
