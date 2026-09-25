#!/usr/bin/env python3
"""
把上游 EeveeSpotifyReincarnated（https://github.com/SideloadLabs/EeveeSpotifyReincarnated）
的其它本地化**迁移并升级**到本仓库。

为什么不能直接拷
================
上游（Reincarnated）那边的 locale 明显落后于本仓库的 `en.lproj`
（例如 `ja` 只有 100 来个键，而本仓库 en 有 230 多个），所以"拷过来"会同时制造两类
**error**（见 TRANSLATING.md / `Tools/l10n_lint.py`）：

  · MISSING —— en 有、locale 没有（app 会回退英文，但 linter 判 error）；
  · EXTRA   —— locale 有、en 没有（那些键在本仓库已被删除/改名，同样是 error）。

所以本脚本做三件事，且**只做这三件**：

  1. **逐字保留**源 locale 里的每一行（注释、空行、顺序都不动）——译文是人的劳动成果；
  2. 删掉**不在 en.lproj 里的键**（EXTRA）；
  3. 把**en 有、locale 没有的键**用**英文原值**补在文件末尾的
     `/* AUTO-FILLED (untranslated) */` 块里（MISSING）——
     值逐字取自 en，所以运行期表现就是英文，不会把 key 名显示给用户。

补出来的块是"待翻译清单"：以后把某条翻译好，就从那个块里挪到上面相应的小节即可。

用法
====
    python Tools/migrate_localizations.py --dry-run      # 只报告，不写文件
    python Tools/migrate_localizations.py                # 迁移全部 locale
    python Tools/migrate_localizations.py --only ja ko   # 只处理指定 locale
    python Tools/migrate_localizations.py --force        # 覆盖已存在的目标文件

写完会**自检**：重新读回目标文件，确认键集与 en 完全一致、没有重复键；
不一致就报错并以退出码 1 结束（这样 CI/人手都能立刻发现）。

设计取舍
========
· 默认**跳过已存在的目标文件**（`--force` 才覆盖）：迁移只做一次，
  之后人工翻译的成果不该被这个脚本冲掉。
· 不改 `Info.plist`：本仓库的 bundle 里只有 `CFBundleDevelopmentRegion`，
  而 iOS 会自动发现新增的 `.lproj`（TRANSLATING.md 说"多数情况下自动生效"）。
  真机上若某语言不出现，再把它的代码加进 `CFBundleLocalizations`。
"""

import argparse
import os
import re
import sys
from pathlib import Path

# 上游（Reincarnated）的 bundle 路径。默认给的是 Windows 上的常规克隆位置；
# 换机器/换目录时**不要改代码**，用环境变量指定即可：
#     EEVEESPOTIFY_UPSTREAM_BUNDLE=/path/to/.../EeveeSpotify.bundle
# 仓库地址见文件头。见 `--help` 里的说明。
SRC_BUNDLE = Path(
    os.environ.get("EEVEESPOTIFY_UPSTREAM_BUNDLE")
    or r"C:\Users\ngzhwm\Documents\GitHub\EeveeSpotifyReincarnated"
    r"\layout\Library\Application Support\EeveeSpotify.bundle"
)
DST_BUNDLE = (
    Path(__file__).resolve().parents[1]
    / "layout"
    / "Library"
    / "Application Support"
    / "EeveeSpotify.bundle"
)

# 本仓库已自带的两个 locale：不迁移（en 是基准；zh-CN 是本地维护的那一份）
SKIP_LOCALES = {"en", "zh-CN"}

ENTRY_START = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=")
AUTO_FILLED_HEADER = """/* AUTO-FILLED (untranslated) — keys that exist in en.lproj but were missing in this
   locale. Values are the English originals (copied verbatim), so runtime behaviour is
   English rather than a raw key name. Translate one, then move it into the matching
   section above and delete it from this block. */"""


def parse_strings(text: str):
    """把 .strings 解析成有序记录：("entry", key, [raw lines]) / ("other", None, [raw line])。

    多行值（en 里就有）也算**同一条**：从 `key = "` 开始，一直吃到以 `";` 结尾的那一行。
    """
    records = []
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        match = ENTRY_START.match(line)
        if not match:
            records.append(("other", None, [line]))
            i += 1
            continue

        key = match.group(1)
        block = [line]
        # 已经是完整的单行条目（以 ; 结尾）就到此为止
        while not block[-1].rstrip().endswith(";"):
            i += 1
            if i >= len(lines):  # 文件尾没有分号：按原样收尾
                break
            block.append(lines[i])
        records.append(("entry", key, block))
        i += 1
    return records


def keys_of(records) -> set:
    return {key for kind, key, _ in records if kind == "entry"}


def merge(source_records, en_records):
    """返回 (merged_lines, kept, dropped, filled)。"""
    en_order = [key for kind, key, _ in en_records if kind == "entry"]
    en_lines = {key: block for kind, key, block in en_records if kind == "entry"}
    en_keys = set(en_order)

    out = []
    kept, dropped = [], []
    for kind, key, block in source_records:
        if kind == "other":
            out.append(block[0])
            continue
        if key in en_keys:
            if key in kept or key in dropped:  # 源文件里重复的键：保留第一条，丢弃其余
                dropped.append(key)
                continue
            out.extend(block)
            kept.append(key)
        else:
            dropped.append(key)

    missing = [key for key in en_order if key not in set(kept)]
    if missing:
        while out and out[-1].strip() == "":
            out.pop()
        out.append("")
        out.append(AUTO_FILLED_HEADER)
        for key in missing:
            out.extend(en_lines[key])
        out.append("")

    return out, kept, dropped, missing


def locale_dirs(bundle: Path):
    return sorted(
        (p.name[: -len(".lproj")] for p in bundle.glob("*.lproj") if p.is_dir())
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="迁移并升级其它本地化")
    parser.add_argument("--dry-run", action="store_true", help="只报告，不写文件")
    parser.add_argument("--force", action="store_true", help="覆盖已存在的目标文件")
    parser.add_argument("--only", nargs="*", default=None, help="只处理这些 locale")
    args = parser.parse_args()

    if not SRC_BUNDLE.is_dir():
        print(f"error: 源 bundle 不存在: {SRC_BUNDLE}", file=sys.stderr)
        return 1

    en_path = DST_BUNDLE / "en.lproj" / "Localizable.strings"
    if not en_path.is_file():
        print(f"error: 基准文件不存在: {en_path}", file=sys.stderr)
        return 1

    en_records = parse_strings(en_path.read_text(encoding="utf-8"))
    en_keys = keys_of(en_records)
    print(f"baseline en.lproj: {len(en_keys)} keys")
    print(f"source: {SRC_BUNDLE}")
    print(f"target: {DST_BUNDLE}\n")

    locales = locale_dirs(SRC_BUNDLE)
    if args.only:
        wanted = {name for name in args.only}
        locales = [name for name in locales if name in wanted]
        unknown = wanted - set(locale_dirs(SRC_BUNDLE))
        if unknown:
            print(f"error: 源里没有这些 locale: {sorted(unknown)}", file=sys.stderr)
            return 1

    failures = []
    summary = []
    for locale in locales:
        if locale in SKIP_LOCALES:
            summary.append((locale, "skipped (已自带)", 0, 0, 0))
            continue

        src_file = SRC_BUNDLE / f"{locale}.lproj" / "Localizable.strings"
        dst_file = DST_BUNDLE / f"{locale}.lproj" / "Localizable.strings"
        if not src_file.is_file():
            failures.append(f"{locale}: 源文件缺失 {src_file}")
            continue
        if dst_file.exists() and not args.force:
            summary.append((locale, "skipped (目标已存在)", 0, 0, 0))
            continue

        merged, kept, dropped, filled = merge(
            parse_strings(src_file.read_text(encoding="utf-8")), en_records
        )
        text = "\n".join(merged)
        if not text.endswith("\n"):
            text += "\n"

        # 自检 1：键集必须与 en 完全一致，且没有重复
        back = parse_strings(text)
        back_keys = [key for kind, key, _ in back if kind == "entry"]
        if len(back_keys) != len(set(back_keys)):
            dupes = sorted({k for k in back_keys if back_keys.count(k) > 1})
            failures.append(f"{locale}: 合并结果里有重复键 {dupes}")
            continue
        if set(back_keys) != en_keys:
            failures.append(
                f"{locale}: 键集仍与 en 不一致 "
                f"(缺 {len(en_keys - set(back_keys))} / 多 {len(set(back_keys) - en_keys)})"
            )
            continue

        if not args.dry_run:
            dst_file.parent.mkdir(parents=True, exist_ok=True)
            dst_file.write_text(text, encoding="utf-8", newline="\n")

        summary.append(
            (locale, "written" if not args.dry_run else "dry-run", len(kept), len(dropped), len(filled))
        )

    print(f"{'locale':8} {'status':22} {'kept':>5} {'dropped':>8} {'filled':>7}")
    for locale, status, kept, dropped, filled in summary:
        print(f"{locale:8} {status:22} {kept:5} {dropped:8} {filled:7}")
    if failures:
        print("\nFAILED:")
        for line in failures:
            print(f"  {line}")
        return 1

    print(f"\nOK — {sum(1 for s in summary if s[1] in ('written', 'dry-run'))} locale(s) processed, 键集与 en 一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
