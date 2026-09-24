#!/usr/bin/env python3
"""
从**解密后的 Spotify IPA** 里离线找出"该 hook 哪个类来写 has_lyrics"。

为什么是"离线脚本"而不是"运行时探针"
--------------------------------------
`SPTPlayerTrackHook` 靠版本号猜类名（`SPTPlayerTrack` / `SPTPlayerTrackImplementation`），
9.1.86 的类表里两个都不存在 → `has_lyrics = "true"` 从来没写进去过。

我先写了个运行时探针去枚举类表，结果**两轮启动崩溃**
（EXC_BREAKPOINT/SIGTRAP，栈在 `_CF_forwarding_prep_0` → `swift_getObjectType`，
寄存器 `__NSGenericDeallocHandler`）。真机上还拿不到日志（一开日志就闪退），
所以那条路彻底放弃：**改成读二进制，不碰运行时**。

它做什么
--------
1. 直接打开 IPA（zip），按中央目录定位 `Payload/Spotify.app/Spotify`；
2. 只读该 zip 条目的**压缩数据**（不把 200MB 二进制解压到磁盘）；
3. 解析 Mach-O 头 + load commands，拿到 `__TEXT,__objc_classname` /
   `__TEXT,__objc_methname` 两个节的**输出偏移与长度**；
4. 用 `zlib.decompressobj()` 分段解压，按"解压后偏移"定位这两个节 ——
   目标节都在文件头部附近，所以只需解压前几 MB，不必把 200MB 全部解开；
   注意本类**只支持按递增偏移读取**（deflate 是单向流），调用顺序必须是
   头部 → classname → methname，与二进制里节的排列一致。
5. 筛出类名候选 + 确认 `metadata` / `URI` 这两个方法名是否存在。

输出
----
一份纯文本报告写进工作区（几 KB），里面有：
  · `metadata` / `URI` 是否在方法名表里 —— 决定 hook 这条路还有没有意义；
  · 名字里带 `Track` 的所有类 —— `targetName` 的候选；
  · 名字里带 `Player` 的所有类 —— 交叉验证用。

用法
----
    python3 extract_player_track_class.py "C:\\dsh\\ipa\\Spotify- Music and Podcasts_9.1.86_decrypted.ipa"
    python3 extract_player_track_class.py <ipa> --out report.txt
"""

import argparse
import os
import struct
import sys
import zipfile

MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19

CLASSNAME_SECTION = "__objc_classname"
METHNAME_SECTION = "__objc_methname"

# 找类名的两条线：
#   ① 精确线：名字里带 Track 的（可能藏着真正的 track 类）；
#   ② 放宽线：带 Player 的（910 时代叫 SPTPlayerTrack，可能换成了 Player* 名字）。
PRIMARY_KEYWORD = "Track"
SECONDARY_KEYWORD = "Player"

REQUIRED_METHODS = ("metadata", "URI")


class DecompressedZipEntry:
    """按偏移区间读取 zip 条目**解压后**的内容，不落盘、不整份进内存。

    ⚠️ 这里**刻意不自己调 zlib**。第一版手写 `zlib.decompressobj(-15)` + 自己算
    "条目的压缩数据起始偏移"，在真机那份 IPA 上直接报：

        zlib.error: Error -3 while decompressing data: invalid block type

    也就是说我对 ZIP 布局的假设（尤其 ZIP64 / data descriptor 场景下
    local header 之后的偏移）是错的，而且手写还照顾不到 store / bzip2 / lzma。
    现在改成**让 zipfile 负责解压**（`ZipExtFile` 自带全部压缩方法），
    我们只做"从头顺序读、读够了就停"：

      · 目标节都在文件头部附近 → 实际只解压前几 MB；
      · 用 `readinto()` 流式读，峰值内存只跟"读到的最大偏移"有关；
      · 本类**只支持按递增偏移读取**（解压流是单向的），调用顺序必须是
        头部 → classname → methname，与二进制里节的排列一致。
    """

    def __init__(self, ipa_path, entry_name, chunk_size=8 << 20):
        self.zf = zipfile.ZipFile(ipa_path)
        try:
            self.info = self.zf.getinfo(entry_name)
        except KeyError:
            self.zf.close()
            raise SystemExit("ERROR: IPA 里没有条目 %r" % entry_name)

        self.compressed_size = self.info.compress_size
        self.uncompressed_size = self.info.file_size
        self._chunk_size = chunk_size
        self._stream = None          # ZipExtFile
        self._has_readinto = False   # 由 _stream_open 探测后置位
        self._buf = bytearray()      # 已解压、从流开头累计
        self._eof = False

    # ── 资源管理：with 语句用 ────────────────────────────────────────────
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False

    def close(self):
        if self._stream is not None:
            try:
                self._stream.close()
            except Exception:
                pass
            self._stream = None
        try:
            self.zf.close()
        except Exception:
            pass

    def _stream_open(self):
        if self._stream is None:
            self._stream = self.zf.open(self.info)
            # 这个版本 Python 的 ZipExtFile 有没有 readinto？（3.7+ 有）
            self._has_readinto = hasattr(self._stream, "readinto")

    def rewind(self):
        """把解压流与内部缓冲重置到文件开头。

        为什么需要：`read()` 会丢弃已经消费掉的头部，而解压流只能前进；
        所以"先用小窗口试读、再换大窗口重读"这类操作**必须**从头再来，
        否则缓冲区与流位置会错位，读出来的是带空洞的数据。
        """
        if self._stream is not None:
            try:
                self._stream.close()
            except Exception:
                pass
        self._stream = None
        self._buf = bytearray()
        self._eof = False
        self._has_readinto = False

    def _fill_to(self, offset):
        """把内部缓冲填充到至少 offset+1 字节（或到文件尾）。"""
        self._stream_open()
        want = offset + 1
        while len(self._buf) < want and not self._eof:
            n = min(self._chunk_size, want - len(self._buf))
            if self._has_readinto:
                block = bytearray(n)
                got = self._stream.readinto(block)
                if not got:
                    self._eof = True
                    break
                self._buf += block[:got]
            else:
                # 老 Python 没有 ZipExtFile.readinto，退回 read()
                data = self._stream.read(n)
                if not data:
                    self._eof = True
                    break
                self._buf += data

    # ── 公开：读 [offset, offset+length) ──────────────────────────────────
    def read(self, offset, length):
        if length <= 0:
            return b""
        self._fill_to(offset + length - 1)
        chunk = bytes(self._buf[offset:offset + length])
        # 已经消费掉的头部丢掉，控制内存（只留可能被后续读取用到的部分）
        if offset > (4 << 20):
            drop = offset - (1 << 20)
            del self._buf[:drop]
        return chunk


def u32(buf, off):
    return struct.unpack_from("<I", buf, off)[0]


def u64(buf, off):
    return struct.unpack_from("<Q", buf, off)[0]


def parse_sections(header):
    """从 Mach-O 头 + load commands 里解析出目标节：(fileoff, size)。

    返回 (found, truncated)：
      · found      —— {节名: (解压后偏移, 长度)}
      · truncated  —— True 表示 buffer 在 load commands 结束前就用完了，
                      也就是"没找到"并不代表"不存在"，必须读更多字节重试。

    ⚠️ 上一版没有这个判断：8MB 窗口不够时循环会因为越界读而悄悄停下，
    于是 `__objc_methname` 被报成"0 个字符串"，看起来像"方法名不存在" ——
    这是一个会误导结论的假阴性，必须显式区分。

    注意：这里的 fileoff 是"解压后文件里的偏移"，正好可以喂给
    DecompressedZipEntry.read()。
    """
    magic = u32(header, 0)
    if magic != MH_MAGIC_64:
        raise SystemExit("ERROR: 不是 64 位 Mach-O（magic=0x%08X）" % magic)

    ncmds = u32(header, 16)
    cmd_off = 32
    found = {}
    for _ in range(ncmds):
        # 这个 command 的头都读不全 → 截断
        if cmd_off + 8 > len(header):
            return found, True
        cmd = u32(header, cmd_off)
        cmdsize = u32(header, cmd_off + 4)
        if cmdsize <= 0:
            return found, True
        # 整个 command（含节头）都要落在 buffer 里
        if cmd_off + cmdsize > len(header):
            return found, True
        if cmd == LC_SEGMENT_64:
            nsects = u32(header, cmd_off + 64)
            sect_off = cmd_off + 72
            for _ in range(nsects):
                if sect_off + 80 > len(header):
                    return found, True
                sectname = header[sect_off:sect_off + 16].split(b"\0")[0].decode("ascii", "replace")
                size = u64(header, sect_off + 40)
                offset = u32(header, sect_off + 48)
                if sectname in (CLASSNAME_SECTION, METHNAME_SECTION) and size and offset:
                    found[sectname] = (offset, size)
                sect_off += 80
        cmd_off += cmdsize
    return found, False


def split_cstrings(raw):
    return [s.decode("utf-8", "replace") for s in raw.split(b"\0") if s]


def find_default_ipa():
    """没给参数时自动找解密 IPA —— 让"双击运行"也能工作。

    搜索顺序固定，命中第一个存在的就返回（优先带 decrypted 的）。
    """
    import glob
    import os

    here = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.abspath(os.path.join(here, "..", ".."))

    patterns = []
    for root in (repo_root, os.path.join(repo_root, "ipa"), r"C:\dsh\ipa"):
        patterns += [
            os.path.join(root, "*decrypted*.ipa"),
            os.path.join(root, "*decrypted*.IPA"),
            os.path.join(root, "*.ipa"),
        ]

    for pattern in patterns:
        hits = sorted(glob.glob(pattern))
        for hit in hits:
            if "decrypted" in os.path.basename(hit).lower():
                return hit
        if hits:
            return hits[0]
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ipa", nargs="?", default=None,
                    help="解密后的 Spotify IPA 路径（省略则自动查找）")
    ap.add_argument("--entry", default=None,
                    help="zip 条目名（默认自动找 Payload/*.app/<appname>）")
    ap.add_argument("--out", default=None, help="报告输出路径（默认写在脚本同目录）")
    args = ap.parse_args()

    if not args.ipa:
        args.ipa = find_default_ipa()
        if not args.ipa:
            raise SystemExit(
                "ERROR: 没找到 IPA。请把解密后的 Spotify IPA 拖到本脚本上，"
                "或用命令行传入路径：\n"
                '    python "%s" "路径\\Spotify- Music and Podcasts_9.1.86_decrypted.ipa"'
                % os.path.basename(__file__)
            )
        print("# 自动选中的 IPA: %s" % args.ipa)

    if not args.out:
        args.out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "player_track_class_report.txt")

    lines = []

    def emit(text=""):
        print(text)
        lines.append(text)

    emit("# Spotify 主二进制离线分析")
    emit("# IPA: %s" % args.ipa)

    with zipfile.ZipFile(args.ipa) as zf:
        names = zf.namelist()
        entry = args.entry
        if entry is None:
            candidates = [
                n for n in names
                if n.startswith("Payload/")
                and n.count("/") == 2
                and not n.endswith("/")
                and n.split("/")[-1].split(".")[0] == n.split("/")[1].replace(".app", "")
            ]
            if not candidates:
                candidates = [n for n in names if n.startswith("Payload/") and n.count("/") == 2 and not n.endswith("/")]
            if not candidates:
                raise SystemExit("ERROR: IPA 里找不到 Payload/*.app/<binary>；用 --entry 指定")
            entry = candidates[0]
    emit("# 条目: %s" % entry)

    # 用 with 包住：ZipExtFile 与 ZipFile 都需要显式关闭。
    with DecompressedZipEntry(args.ipa, entry) as src:
        emit("# 压缩 %d 字节 / 解压 %d 字节" % (src.compressed_size, src.uncompressed_size))

        # 读 Mach-O 头 + load commands。
        #
        # ⚠️ 这里必须**循环扩大窗口**：上一版固定 8MB，遇到 load commands 更长时
        # parse_sections 会静默截断，把 `__objc_methname` 报成"0 个字符串"，
        # 看起来像"方法名不存在"。现在按 truncated 标志 4MB → 256MB 逐步重读。
        sections = {}
        truncated = True
        window = 4 << 20
        while window <= (128 << 20):
            src.rewind()          # 每次换窗口都从头读，避免缓冲/流位置错位
            header = src.read(0, window)
            sections, truncated = parse_sections(header)
            has_both = CLASSNAME_SECTION in sections and METHNAME_SECTION in sections
            emit("# 读取窗口 %d MB → 节: %s%s"
                 % (window >> 20,
                    ", ".join(sorted(sections.keys())) or "(无)",
                    "" if (has_both and not truncated) else "（还缺目标节/被截断，扩大窗口重试）"))
            if has_both and not truncated:
                break
            window <<= 1

        class_names, method_names = [], []
        if CLASSNAME_SECTION in sections:
            off, size = sections[CLASSNAME_SECTION]
            class_names = split_cstrings(src.read(off, size))
        if METHNAME_SECTION in sections:
            off, size = sections[METHNAME_SECTION]
            method_names = split_cstrings(src.read(off, size))

    emit("# __objc_classname: %d 个字符串" % len(class_names))
    emit("# __objc_methname : %d 个字符串%s"
         % (len(method_names),
            "" if method_names else "  ← 解析不完整或该节为空，下面的 [1] 不可信"))

    emit()
    emit("[1] 目标方法名是否存在（决定 hook 这条路还有没有意义）")
    if not method_names:
        emit("    **无法判定**：__objc_methname 没解析到内容，")
        emit("    这一节不可信 —— 不要据此认为方法名不存在。")
    else:
        for name in REQUIRED_METHODS:
            emit("    %-10s %s" % (name, "存在" if name in method_names else "**不存在**"))

    emit()
    emit("[2] 名字带 '%s' 的类（targetName 首选候选）" % PRIMARY_KEYWORD)
    primary = sorted({n for n in class_names if PRIMARY_KEYWORD in n})
    if primary:
        for n in primary:
            emit("    " + n)
    else:
        emit("    （无）")

    emit()
    emit("[3] 名字带 '%s' 的类（交叉验证）" % SECONDARY_KEYWORD)
    secondary = sorted({n for n in class_names if SECONDARY_KEYWORD in n})
    if secondary:
        for n in secondary:
            emit("    " + n)
    else:
        emit("    （无）")

    # 旧代码猜的两个名字，直接给出存在性，省得再猜
    emit()
    emit("[4] 旧代码猜过的类名是否真的存在")
    for name in ("SPTPlayerTrack", "SPTPlayerTrackImplementation"):
        emit("    %-30s %s" % (name, "存在" if name in class_names else "不存在"))

    # 附带：命名空间清单（Swift 类名形如 Module.Class，老 ObjC 类名无点）
    emit()
    emit("[5] 含 '%s' 的类的命名空间分布" % PRIMARY_KEYWORD)
    prefixes = {}
    for n in primary:
        prefix = n.split(".")[0] if "." in n else "(无 module 前缀/ObjC)"
        prefixes[prefix] = prefixes.get(prefix, 0) + 1
    for prefix, count in sorted(prefixes.items(), key=lambda kv: -kv[1]):
        emit("    %-45s %d" % (prefix, count))

    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    print("\n# 报告已写入 %s" % args.out)
    return 0


if __name__ == "__main__":
    try:
        code = main()
    except SystemExit as exc:
        # argparse 的正常退出也会到这里；把消息打出来再暂停，双击运行才看得到。
        if exc.code not in (0, None):
            print(exc.code)
        code = exc.code if isinstance(exc.code, int) else 1
    except Exception:
        import traceback
        traceback.print_exc()
        code = 1

    # 双击运行时窗口会在结束瞬间关掉 —— 停一下让用户看到结果。
    try:
        input("\n按回车键关闭…")
    except EOFError:
        pass
    sys.exit(code)
