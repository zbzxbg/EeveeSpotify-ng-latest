#!/usr/bin/env python3
"""
离线定位 9.1.x 上"真正持有 `has_lyrics` 的 track 类"。

为什么需要它
------------
`SPTPlayerTrackHook`（Sources/EeveeSpotify/Lyrics/CustomLyrics+AllTracksLyrics.swift）
靠**版本号猜类名**去 hook `SPTPlayerTrack` / `SPTPlayerTrackImplementation`，用来把
track 元数据里的 `has_lyrics` 覆写成 "true"。9.1.86 的类表里这两个名字都不存在
（见 Scripts/dump-spotify-symbols.py 的 [classes] 桶），所以这条 hook 从来没生效过。

先前我写过一个"运行时枚举所有类"的探针去找它 —— 结果是两轮启动崩溃
（EXC_BREAKPOINT/SIGTRAP，栈在 _CF_forwarding_prep_0 → swift_getObjectType）。
真机拿不到日志就没法用它。所以改成**纯离线**：直接读二进制，不动运行时。

它看什么
--------
Mach-O 的 `__TEXT,__objc_classname` 段里是**类名字符串表**，
`__TEXT,__objc_methname` 段里是**方法名字符串表**，两者都是普通 C 字符串、连续存放。
所以"哪些类叫得像个 track 类"是可以直接从字符串表里筛出来的，不需要解析
classlist/methodlist 那些 pointer 结构（指针在 __DATA 里，还有链式 fixup，容易读错）。

局限（必须说清楚）
------------------
这个方法只能给出**类名候选**，给不出"这个类是否真的实现 metadata()/URI()"。
要那一步得解析 `__objc_classlist` + `__objc_data`（指针 + 链式 fixup）。
所以本脚本的输出仍然需要一次人工/半自动确认 —— 但它把候选从 1.7 万个缩到个位数，
而且**不需要在设备上跑任何东西**。

用法
----
    python3 find_player_track_class.py <Spotify-binary>

二进制从哪来：解密后的 IPA（zip）里 `Payload/Spotify.app/Spotify`。
"""

import argparse
import re
import struct
import sys

# ── Mach-O 常量 ──────────────────────────────────────────────────────────────
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA
FAT_MAGIC_64 = 0xCAFEBABF
FAT_CIGAM_64 = 0xBFBAFECA
CPU_TYPE_ARM64 = 0x0100000C
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x02

# ── 目标段 ───────────────────────────────────────────────────────────────────
# __objc_classname: 类名字符串表；__objc_methname: 方法名字符串表。
CLASSNAME_SECTION = "__objc_classname"
METHNAME_SECTION = "__objc_methname"

# 我们要找的类：名字里带 Track/Player 的（SPTPlayerTrack 已被证伪，
# 所以放宽到"看起来像播放器曲目"的所有命名空间）。
CLASS_NAME_RE = re.compile(
    r"^(?:SPT|SPTPlayer|Player|NowPlaying_|Lyrics_|Stateful|Connect_|Playback_)?"
    r"[A-Za-z0-9_]*"
    r"(?:PlayerTrack|TrackPlayer|NowPlayingTrack|TrackMetadata|TrackImpl|PlayerTrackImpl)"
    r"[A-Za-z0-9_]*$"
)

# 这两个方法同时存在，才说明该类是 track 类（本仓库 @objc protocol SPTPlayerTrack
# 就是这么声明的）。它们出现在 __objc_methname 里。
REQUIRED_METHODS = ("metadata", "URI")


def _u32(buf, off, big=False):
    return int.from_bytes(buf[off:off + 4], "big" if big else "little")


def find_macho_offset(blob):
    """返回 (offset, size) —— 目标 arm64 slice 在文件里的位置。"""
    magic = _u32(blob, 0)
    if magic in (MH_MAGIC_64, 0xFEEDFACE):
        return 0, len(blob)
    if magic in (FAT_MAGIC, FAT_MAGIC_64, FAT_CIGAM, FAT_CIGAM_64):
        big = magic in (FAT_MAGIC, FAT_MAGIC_64)
        is64 = magic in (FAT_MAGIC_64, FAT_CIGAM_64)
        nfat = _u32(blob, 4, big)
        entry_size = 32 if is64 else 20
        for i in range(nfat):
            base = 8 + i * entry_size
            cpu = _u32(blob, base, big)
            off = _u32(blob, base + 8, big)
            size = _u32(blob, base + 12, big)
            if cpu == CPU_TYPE_ARM64:
                return off, size
        # 没有 arm64 就退回第一个 slice
        return _u32(blob, 8 + 8, big), _u32(blob, 8 + 12, big)
    raise SystemExit("ERROR: 不是 Mach-O（magic=0x%08X）。IPA 是否已解密？" % magic)


def iter_sections(blob, slice_off):
    """遍历 64 位 Mach-O 的段/节，yield (segname, sectname, file_offset, size)。"""
    ncmds = _u32(blob, slice_off + 16)
    cmd_off = slice_off + 32
    for _ in range(ncmds):
        cmd = _u32(blob, cmd_off)
        cmdsize = _u32(blob, cmd_off + 4)
        if cmdsize <= 0:
            break
        if cmd == LC_SEGMENT_64:
            segname = blob[cmd_off + 8:cmd_off + 24].split(b"\0")[0].decode("ascii", "replace")
            nsects = _u32(blob, cmd_off + 64)
            sect_off = cmd_off + 72
            for _ in range(nsects):
                sectname = blob[sect_off:sect_off + 16].split(b"\0")[0].decode("ascii", "replace")
                addr = int.from_bytes(blob[sect_off + 32:sect_off + 40], "little")
                size = int.from_bytes(blob[sect_off + 40:sect_off + 48], "little")
                offset = _u32(blob, sect_off + 48)
                if size and offset:
                    yield segname, sectname, offset, size, addr
                sect_off += 80
        cmd_off += cmdsize


def split_cstrings(raw):
    """把一段连续的 C 字符串表拆成列表（跳过空串）。"""
    return [s.decode("utf-8", "replace") for s in raw.split(b"\0") if s]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("binary", help="解密后的 Spotify 主二进制（Mach-O）")
    ap.add_argument("--all", action="store_true", help="列出所有 __objc_classname 里的类名（不筛）")
    args = ap.parse_args()

    with open(args.binary, "rb") as fh:
        blob = fh.read()
    print("# 读取 %d 字节" % len(blob))

    slice_off, slice_size = find_macho_offset(blob)
    print("# arm64 slice @ 0x%X (size 0x%X)" % (slice_off, slice_size))

    sections = list(iter_sections(blob, slice_off))
    if not sections:
        raise SystemExit("ERROR: 没解析出任何 section")

    class_raw = b""
    meth_raw = b""
    for segname, sectname, offset, size, addr in sections:
        if sectname == CLASSNAME_SECTION:
            class_raw = blob[offset:offset + size]
        elif sectname == METHNAME_SECTION:
            meth_raw = blob[offset:offset + size]

    if not class_raw:
        print("!! 没找到 %s —— 这个二进制可能被 strip 过类名字符串" % CLASSNAME_SECTION)
    if not meth_raw:
        print("!! 没找到 %s" % METHNAME_SECTION)

    class_names = split_cstrings(class_raw)
    method_names = split_cstrings(meth_raw)
    print("# __objc_classname: %d 个字符串" % len(class_names))
    print("# __objc_methname : %d 个字符串" % len(method_names))

    # ① 这两个方法名是否存在，决定了"hook metadata()/URI()"这条路还有没有意义。
    print("\n[1] 目标方法名是否出现在 __objc_methname：")
    for name in REQUIRED_METHODS:
        print("    %-10s %s" % (name, "存在" if name in method_names else "**不存在**"))

    # ② 名字里带 PlayerTrack/TrackPlayer 之类的类 —— 这些就是 targetName 候选。
    matches = sorted({n for n in class_names if CLASS_NAME_RE.match(n)})
    print("\n[2] 类名候选（%d 个）：" % len(matches))
    if matches:
        for name in matches:
            print("    " + name)
    else:
        print("    （没有匹配。用 --all 看全量类名，或放宽 CLASS_NAME_RE）")

    # ③ 顺带把可能的命名空间前缀列出来，方便判断该往哪个 module 找。
    print("\n[3] 名字里含 Track 的全部类（不筛前缀，供交叉验证）：")
    trackish = sorted({n for n in class_names if "Track" in n})
    for name in trackish[:80]:
        print("    " + name)
    if len(trackish) > 80:
        print("    …（共 %d 个，只显示前 80）" % len(trackish))

    if args.all:
        print("\n[4] 全量类名：")
        for name in sorted(class_names):
            print("    " + name)


if __name__ == "__main__":
    sys.exit(main())
