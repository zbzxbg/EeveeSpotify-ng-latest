#!/usr/bin/env python3
"""
定位"Spotify 9.1.x 上到底是哪一步决定歌词模块（预览卡片）建不建"。

为什么需要这个脚本
==================
9.1.0 → 9.1.86 之间，Spotify 把歌词 UI 从"常驻容器"重写成了"组件 + 可用性判定"：

  9.1.0  有 `Lyrics_NPVCommunicatorImpl.LyricsOnlyViewController` / `.ScrollProvider` / `.CardView`
  9.1.86 这些**全部消失**，换成 `Lyrics_CardElementImpl.*` / `Lyrics_NPVElementsKitImpl.*`
          / `Lyrics_CoreInternalImpl.*`，并新增 `Lyrics_OfflineImpl.*`（SQLite 离线歌词）

后果：EeveeSpotify 那套"让每首歌都有歌词模块"的 hook（`SPTPlayerTrackHook.metadata()`
写 `has_lyrics=true`、`LyricsScrollProviderHook.isEnabledForTrack()`）在 9.1.x 上
**靶子不存在**，于是"有些歌完全没有歌词模块"。

本脚本不碰运行时，只读解密 IPA 的 Mach-O，回答四个问题：

  [1] `has_lyrics` 这个键在二进制里到底和什么在一起？（谁能写它、scope 是什么）
  [2] 名字里带 Lyric 的 **Swift 符号**（demangle 后的可读名）有哪些方法名可选出来？
  [3] 哪个类的符号里同时出现"可用性/卡片/创建"这一类词？（判定点的候选）
  [4] `Lyrics_OfflineImpl` 的存取接口长什么样？（"本地有词就不用请求"这条路）

用法
====
    python find_lyrics_gate.py "C:\\dsh\\ipa\\Spotify- Music and Podcasts_9.1.86_decrypted.ipa"
    python find_lyrics_gate.py <ipa> --out report.txt
    python find_lyrics_gate.py <ipa> --section swift      # 只看某一节

设计约束（踩过的坑）
====================
· IPA 是 zip，主二进制 ~240MB。**只读这一个条目**，不整包解压（zipfile 自己解压）。
· 目标节（__objc_methname / __cstring / __swift5_*）都在文件前部附近，
  但 `__cstring` 可能很靠后 —— 所以本脚本用**整条读入**（约 240MB 内存），
  换取"任意偏移可重复读"的能力，避免流式 read 的单向性把逻辑搞复杂。
· 不假设 ObjC 选择器存在：9.1.x 的歌词组件是纯 Swift，
  方法名只能从**类型上下文**（module.Class + 相邻方法名符号）里推。
"""

import argparse
import os
import re
import struct
import sys
import zipfile

# ── Mach-O 常量 ────────────────────────────────────────────────────────────
MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA
FAT_MAGIC_64 = 0xCAFEBABF
FAT_CIGAM_64 = 0xBFBAFECA

LC_SEGMENT_64 = 0x19

# 我们关心的节
SECTIONS_OF_INTEREST = (
    "__objc_classname",
    "__objc_methname",
    "__cstring",
    "__swift5_typeref",
    "__swift5_reflstr",
    "__swift5_fieldmd",
    "__swift5_proto",
)

# ── 关键词 ────────────────────────────────────────────────────────────────
# 判定点候选：卡片建不建、有没有词、可用不可用
GATE_WORDS = (
    "availability", "available", "shouldshow", "shouldhide", "canshow",
    "haslyrics", "has_lyrics", "nocontent", "isempty", "isplaceholder",
    "shoulddisplay", "shouldrender", "shouldcreate", "makeelement",
    "elementfactory", "buildcard", "showcard", "hidecard",
)

LYRICS_WORD = "lyric"


def u32(buf, off, big=False):
    return int.from_bytes(buf[off:off + 4], "big" if big else "little")


def u64(buf, off, big=False):
    return int.from_bytes(buf[off:off + 8], "big" if big else "little")


def macho_slice_offset(blob):
    """返回 (offset, size) 指向 arm64（或首个 64 位）切片。"""
    magic_le = u32(blob, 0)
    magic_be = u32(blob, 0, big=True)

    if magic_le in (MH_MAGIC_64, MH_CIGAM_64):
        return 0, len(blob)

    if magic_be in (FAT_MAGIC, FAT_MAGIC_64) or magic_le in (FAT_MAGIC, FAT_MAGIC_64):
        big = magic_be in (FAT_MAGIC, FAT_MAGIC_64)
        nfat = u32(blob, 4, big=big)
        entry = 32 if (magic_be in (FAT_MAGIC_64,) or magic_le in (FAT_MAGIC_64,)) else 20
        fallback = None
        for i in range(nfat):
            base = 8 + i * entry
            cpu = u32(blob, base, big=big)
            off = u32(blob, base + 8, big=big)
            size = u32(blob, base + 12, big=big)
            if cpu == 0x0100000C:          # arm64
                return off, size
            if fallback is None:
                fallback = (off, size)
        if fallback:
            return fallback

    raise SystemExit("ERROR: 不是可识别的 Mach-O/fat 头（magic=0x%08X）。IPA 解密了吗？" % magic_le)


def parse_sections(slice_bytes):
    """解析 load commands，返回 {节名: (offset, size)}（offset 相对切片起点）。"""
    if u32(slice_bytes, 0) != MH_MAGIC_64:
        raise SystemExit("ERROR: 切片不是 64 位 Mach-O（magic=0x%08X）" % u32(slice_bytes, 0))

    ncmds = u32(slice_bytes, 16)
    off = 32
    found = {}
    for _ in range(ncmds):
        if off + 8 > len(slice_bytes):
            break
        cmd = u32(slice_bytes, off)
        cmdsize = u32(slice_bytes, off + 4)
        if cmdsize <= 0:
            break
        if cmd == LC_SEGMENT_64:
            nsects = u32(slice_bytes, off + 64)
            sect_off = off + 72
            for _ in range(nsects):
                if sect_off + 80 > len(slice_bytes):
                    break
                sectname = slice_bytes[sect_off:sect_off + 16].split(b"\0")[0].decode("ascii", "replace")
                size = u64(slice_bytes, sect_off + 40)
                fileoff = u32(slice_bytes, sect_off + 48)
                if size and fileoff:
                    found.setdefault(sectname, (fileoff, size))
                sect_off += 80
        off += cmdsize
    return found


def cstrings(raw):
    return [s.decode("utf-8", "replace") for s in raw.split(b"\0") if s]


def load_slice(ipa_path, entry_name=None):
    with zipfile.ZipFile(ipa_path) as zf:
        names = zf.namelist()
        if entry_name is None:
            cands = [n for n in names
                     if n.startswith("Payload/") and n.count("/") == 2 and not n.endswith("/")]
            if not cands:
                raise SystemExit("ERROR: IPA 里找不到 Payload/*.app/<binary>")
            # 主二进制 = .app 目录内那个与 .app 同名、无扩展名的条目
            entry_name = None
            for n in cands:
                app = n.split("/")[1]
                if n.split("/")[-1] == app[:-4]:
                    entry_name = n
                    break
            if entry_name is None:
                entry_name = cands[0]
        print("# 条目: %s" % entry_name)
        blob = zf.read(entry_name)
    print("# 条目解压后 %d 字节" % len(blob))
    off, size = macho_slice_offset(blob)
    print("# arm64 切片 offset=%d size=%d" % (off, size))
    return blob[off:off + size], entry_name


# ── 报告各节 ──────────────────────────────────────────────────────────────

def report_has_lyrics_context(strings, emit):
    """[1] has_lyrics 键的上下文：谁在读写它、周围还有什么键。"""
    emit("[1] `has_lyrics` / `hasLyrics` 上下文")
    hits = [s for s in strings if "has_lyrics" in s or "hasLyrics" in s]
    if not hits:
        emit("    （__cstring 里没有 has_lyrics/hasLyrics —— 键名可能是拼出来的）")
    for h in sorted(set(hits))[:40]:
        emit("    %s" % h)

    emit("")
    emit("    邻近的 flag（含 lyrics 的 enable_* 名字，用于确认真实 scope）：")
    flags = sorted({s for s in strings if re.fullmatch(r"(?:enable|ios|s2s|catalog)_[a-z0-9_]*lyric[a-z0-9_]*", s)})
    for f in flags:
        emit("      %s" % f)


def report_swift_symbols(strings, emit):
    """[2][3] Swift 符号：歌词相关模块的方法名与判定点候选。"""
    emit("[2] 含 lyric 的符号串（Swift 名 / 类型上下文 / 方法名候选）")
    sym = sorted({s for s in strings
                  if LYRICS_WORD in s.lower() and 4 <= len(s) <= 200})
    emit("    总计 %d 条，下面按『是否像方法名』分组：" % len(sym))

    method_like = [s for s in sym if re.search(r"[a-z][A-Za-z0-9]*\(", s) or ":" in s]
    type_like = [s for s in sym if re.fullmatch(r"[A-Za-z0-9_]+\.[A-Za-z0-9_]+", s)]

    emit("")
    emit("    ── 判定点候选方法（含 gate 关键词） ──")
    gates = []
    for s in sym:
        low = s.lower()
        if any(w in low for w in GATE_WORDS):
            gates.append(s)
    for g in sorted(set(gates))[:120]:
        emit("      %s" % g)
    if not gates:
        emit("      （没有直接命中；看下面的类型/方法串自己判断）")

    emit("")
    emit("    ── 类型名（module.Class 形式，已排除噪音前缀） ──")
    for t in type_like[:200]:
        if t.split(".")[0] in ("Foundation", "Swift", "UIKit", "CoreFoundation"):
            continue
        emit("      %s" % t)

    emit("")
    emit("    ── 方法/属性形状的串（前 200 条，人工扫 gate） ──")
    for m in sorted(set(method_like))[:200]:
        emit("      %s" % m)


def report_section_sizes(sections, emit):
    emit("[0] 目标节")
    for name in SECTIONS_OF_INTEREST:
        if name in sections:
            off, size = sections[name]
            emit("    %-22s off=%-12d size=%d" % (name, off, size))
        else:
            emit("    %-22s （不存在）" % name)


def report_offline(strings, emit):
    """[4] Lyrics_OfflineImpl 的接口线索。"""
    emit("[4] Lyrics_OfflineImpl（离线歌词存储）接口线索")
    keys = ("LyricsOffline", "lyrics_offline", "lyricsOffline", "PlaybackId")
    hits = sorted({s for s in strings if any(k in s for k in keys)})
    if not hits:
        emit("    （__cstring 里没有 —— 类型名只在 Swift 符号里，看 [2] 的类型清单）")
    for h in hits[:80]:
        emit("    %s" % h)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ipa", nargs="?", default=None, help="解密后的 Spotify IPA")
    ap.add_argument("--entry", default=None, help="zip 条目名（默认自动找主二进制）")
    ap.add_argument("--out", default=None, help="报告输出路径")
    ap.add_argument("--section", default="all",
                    choices=("all", "sizes", "haslyrics", "swift", "offline"))
    args = ap.parse_args()

    if not args.ipa:
        for pat in (r"C:\dsh\ipa", os.path.expanduser("~/Downloads"), os.getcwd()):
            if os.path.isdir(pat):
                for fn in sorted(os.listdir(pat)):
                    if fn.lower().endswith(".ipa") and "decrypted" in fn.lower():
                        args.ipa = os.path.join(pat, fn)
                        break
            if args.ipa:
                break
        if not args.ipa:
            raise SystemExit("ERROR: 没找到解密 IPA，请用参数传入路径")

    if not args.out:
        args.out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "lyrics_gate_report.txt")

    lines = []

    def emit(text=""):
        print(text)
        lines.append(text)

    emit("# Spotify 歌词模块判定点取证")
    emit("# IPA: %s" % args.ipa)
    emit()

    data, entry = load_slice(args.ipa, args.entry)
    sections = parse_sections(data)
    emit()

    if args.section in ("all", "sizes"):
        report_section_sizes(sections, emit)
        emit()

    # 需要字符串的节
    need_strings = args.section in ("all", "haslyrics", "swift", "offline")
    strings = []
    if need_strings:
        for name in ("__cstring", "__objc_methname", "__objc_classname",
                     "__swift5_reflstr"):
            if name in sections:
                off, size = sections[name]
                strings.extend(cstrings(data[off:off + size]))
        emit("# 共解析字符串 %d 条" % len(strings))
        emit()

    if args.section in ("all", "haslyrics"):
        report_has_lyrics_context(strings, emit)
        emit()
    if args.section in ("all", "swift"):
        report_swift_symbols(strings, emit)
        emit()
    if args.section in ("all", "offline"):
        report_offline(strings, emit)

    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    print("\n# 报告已写入 %s" % args.out)
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
