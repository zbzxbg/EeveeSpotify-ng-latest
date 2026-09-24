#!/usr/bin/env python3
"""
Diff two symbol dumps (from dump-spotify-symbols.py) and report what a
Spotify update changed in terms of hook impact.

Severity model:
  - Classes that EeveeSpotify hooks (targetName / NSClassFromString) are
    CRITICAL when they vanish — those hooks silently stop working.
  - RPC removals/renames are HIGH (matches the FetchMessage/pendragon class
    of breakage).
  - Everything else is informational (ADDED/REMOVED/RENAMED-SUSPECT lines).

Usage:
  diff-symbol-dumps.py <old_dump.txt> <new_dump.txt> [--tweak-sources DIR]
                       [-o report.md]

Source: EeveeSpotifyReincarnated/Scripts/diff-symbol-dumps.py, with one
deliberate change (see `tweak_hook_names` below).

────────────────────────────────────────────────────────────────────────────
⚠️ 与原版的差别：hook 目标提取不再只认 mangled 写法
────────────────────────────────────────────────────────────────────────────
原版只匹配 `"(_TtC[^"]+)"` 字面量，只看得到这样写的目标：

    static let targetName = "_TtC24Connectivity_SessionImpl18SessionServiceImpl"

但这个项目里**大量**目标（歌词那一整套、NPV 宿主、卡片容器）是用点号写法：

    static let targetName = "Lyrics_FullscreenElementPageImpl.FullscreenElementViewController"
    static let targetName = "NowPlaying_ScrollImpl.NPVScrollViewController"
    static let targetName = "Lyrics_TextElementImpl.LyricsTextView"

原版对这类目标**一条都不检查** —— 于是报告里"词汇表全绿"，而真正
依赖最深的歌词 hook 压根没进范围，看着安全其实没覆盖。

现在点号写法也纳入：dump 出来的 classes 是 mangled 形式
（`_TtC22Lyrics_TextElementImpl14LyricsTextView`），所以判定用
"模块名 and 类名都在同一个 mangled 串里" 的子串匹配，而不是等值比较。

⚠️ 子串匹配的已知偏差（它会**漏报** CRITICAL）
────────────────────────────────────────────────────────────────────────
判定规则是 `mod in mangled and cls in mangled`。短类名会互相串味：
目标是 `Lyrics_CardElementImpl.CardView` 时，mangled 串
`_TtC22Lyrics_CardElementImpl8CardView` 里既含 "Lyrics_CardElementImpl" 也含
"CardView"，正常命中；但目标是 `Lyrics_NPVCommunicatorImpl.CardView`（老版本
写法）时，同一串里的 "CardView" 也会让它命中 —— 于是这个"其实已经不存在"
的目标被算成"还在"。

方向是明确的：**这个规则对"存在"不可靠，对"消失"可靠。**
  · 报"消失"→ 可信（所有 mangled 串里都找不到模块名+类名）
  · 报"还在"→ 不可信（可能只是被同名类蹭中了）
后果就是**可能漏掉本该报的 CRITICAL**，不会反过来误报。

所以：点号那部分的结果要和 mangled 那部分一起看，**"全绿"不等于保证**。
要精确结论，仍然只有装到设备上跑、看
`[ORION ERROR] Failed to hook method ...`。
"""

import argparse
import glob
import io
import os
import re
import sys

BUCKETS = ("classes", "rpc", "flags", "methods", "selectors")

# mangled 写法："_TtC…"（原版唯一认可的）
MANGLED_RE = re.compile(r'"(_TtC[A-Za-z0-9_]+)"')
# 点号写法："模块.类名"，例如 Lyrics_TextElementImpl.LyricsTextView
DOTTED_RE = re.compile(r'"([A-Za-z][A-Za-z0-9_]*\.[A-Z][A-Za-z0-9_]+)"')


def parse_dump(path):
    buckets = {b: set() for b in BUCKETS}
    current = None
    with io.open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            m = re.match(r"^\[([a-z]+)\]", line)
            if m:
                current = m.group(1) if m.group(1) in buckets else None
                continue
            if current:
                buckets[current].add(line)
    return buckets


def tweak_hook_names(sources_dir):
    """扫描源码，返回两类 hook 目标：
       mangled  —— 形如 `_TtC…`，可与 dump 里的 classes **等值**比较
       dotted   —— 形如 `模块.类名`，需要用**子串**在 mangled 串里找
    """
    mangled = set()
    dotted = set()
    for path in glob.glob(os.path.join(sources_dir, "**", "*.swift"), recursive=True):
        try:
            with io.open(path, "r", encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError:
            continue
        mangled.update(MANGLED_RE.findall(text))
        for mod, cls in (d.split(".", 1) for d in DOTTED_RE.findall(text)):
            # 只收看起来像 Spotify 内部模块的（`Xxx_YyyImpl` 这种命名），
            # 否则 Foundation.NSObject、Swift.String 这类会灌进来一堆噪音。
            if "_" in mod and (mod.endswith("Impl") or "Impl" in mod):
                dotted.add((mod, cls))
    return mangled, dotted


# 判定"这个 dump 里的 mangled 类名是否就是某个点号目标"
def dotted_matches(mangled_name, mod, cls):
    return mod in mangled_name and cls in mangled_name


def diff_bucket(old, new):
    return sorted(old - new), sorted(new - old)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("old_dump")
    ap.add_argument("new_dump")
    ap.add_argument("--tweak-sources", default="Sources/EeveeSpotify",
                    help="tweak sources dir to scan for hooked class names")
    ap.add_argument("-o", "--output", default="-")
    args = ap.parse_args()

    old = parse_dump(args.old_dump)
    new = parse_dump(args.new_dump)
    mangled, dotted = tweak_hook_names(args.tweak_sources)

    crit, high, lines = [], [], []

    for bucket in BUCKETS:
        removed, added = diff_bucket(old[bucket], new[bucket])
        if bucket == "classes":
            gone_hooks = [c for c in removed if c in mangled]
            if gone_hooks:
                crit.append("Hooked classes no longer present in the new binary:")
                crit.extend("  - %s" % c for c in sorted(gone_hooks))

            # 点号写法：padded 时在 new 里还找得到，removed 时找不到了
            gone_dotted = []
            for mod, cls in sorted(dotted):
                if any(dotted_matches(n, mod, cls) for n in new[bucket]):
                    continue
                if any(dotted_matches(o, mod, cls) for o in old[bucket]):
                    gone_dotted.append("%s.%s" % (mod, cls))
            if gone_dotted:
                crit.append("Hooked classes (dotted targetName form) gone:")
                crit.extend("  - %s" % c for c in sorted(gone_dotted))

        if bucket == "rpc":
            gone_rpc = [c for c in removed if "pendragon" in c or "customize" in c
                        or "bootstrap" in c or "ads" in c.lower()]
            if gone_rpc:
                high.append("Ad/Premium-relevant RPCs removed (check URL+Extension.swift):")
                high.extend("  - %s" % c for c in sorted(gone_rpc))

        if removed or added:
            lines.append("")
            lines.append("## [%s]  −%d / +%d" % (bucket, len(removed), len(added)))
            if removed:
                lines.append("")
                lines.append("### Removed (%d)" % len(removed))
                lines.extend("- `%s`" % s for s in removed[:400])
                if len(removed) > 400:
                    lines.append("- … and %d more" % (len(removed) - 400))
            if added:
                lines.append("")
                lines.append("### Added (%d)" % len(added))
                lines.extend("- `%s`" % s for s in added[:400])
                if len(added) > 400:
                    lines.append("- … and %d more" % (len(added) - 400))

    header = ["# Spotify symbol diff", "",
              "old: `%s`" % args.old_dump,
              "new: `%s`" % args.new_dump, "",
              "hook 目标覆盖：mangled %d 个，点号写法 %d 个"
              % (len(mangled), len(dotted)), ""]

    verdict = "CLEAN"
    if crit:
        verdict = "CRITICAL"
        header.append("## ⛔ CRITICAL — hooks will silently stop working")
        header.extend(crit)
        header.append("")
    if high:
        if verdict == "CLEAN":
            verdict = "HIGH"
        header.append("## ⚠️ HIGH — ad/Premium-relevant RPCs changed")
        header.extend(high)
        header.append("")
    if verdict == "CLEAN":
        header.append("## ✅ No critical or high-impact changes detected")
        header.append("")
        header.append("(cosmetic bucket changes, if any, are listed below)")
        header.append("")

    text = "\n".join(header + lines) + "\n"
    if args.output == "-":
        sys.stdout.write(text)
    else:
        with io.open(args.output, "w", encoding="utf-8") as f:
            f.write(text)
        sys.stderr.write("diff verdict: %s\n" % verdict)
    # Non-zero exit on critical findings so CI can surface them loudly,
    # without failing the whole run.
    sys.exit(0 if not crit else 3)


if __name__ == "__main__":
    main()
