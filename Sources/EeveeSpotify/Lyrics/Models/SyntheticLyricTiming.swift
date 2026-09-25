import Foundation

/// 给「没有行级时间轴」的歌词合成时间轴。
///
/// ── 为什么需要（真机取证结论）──────────────────────────────────────────────
/// Spotify 9.1.x 把 NPV 歌词模块重写成了响应驱动的组件（`Lyrics_CardElementImpl.*` /
/// `Lyrics_NPVElementsKitImpl.*`）。真机日志显示：
///
///   · 正常显示的歌：`line timing 54/54 -> line-level=Y | timeSynced=true`；
///   · 显示不出歌词的歌：payload 是**无时间轴**的占位/纯文本
///     （`[NetEase] No usable lyrics` → `serving our placeholder` →
///      `attach declined — not even line-level timing is available`）。
///
/// 也就是说：**无时间轴的 payload 在这个版本上等于"不可用"**。
/// Genius 这一类源给出的本来就是 `timeSynced: false` 的纯文本，
/// 与占位文案同病 —— 这正是"开了 Genius 回退反而更严重"的机制。
///
/// 本文件把"按曲目时长把每一行铺到时间轴上"这件事收敛到一处：
/// 只要交给 Spotify 的 payload 恒带行级时间轴，"每首歌都有模块"这个目标
/// 就不再受"源有没有时间轴"的影响。
///
/// ── 边界（重要）──────────────────────────────────────────────────────────
/// · 只改**注入给 Spotify 的那份 protobuf**，不改 `currentLyricsDto`。
///   渲染层的判据（`hasUsableWordLevelData` / `hasUsableLineLevelData`）读的还是原始 dto，
///   所以不会因为合成时间轴而突然挂上一层"假同步"的高亮或逐词层。
/// · 合成是**近似**的：行会按字符权重被铺在曲目时长上，位置不保证准确。
///   它换来的是"模块能出现"，不是"逐行对得准"。
enum SyntheticLyricTiming {

    /// 每行至少占用的时长，避免超短行被压成 0ms 导致相邻行 offset 相同。
    private static let minimumLineMs = 900

    /// 字符权重的下限：空行/极短行（副歌间的空档）也要占到一点时间。
    private static let minimumWeight = 4

    /// 拿不到曲目时长时的兜底单行时长。
    private static let fallbackLineMs = 4000

    /// 判定"这份数据已经自带时间轴"：至少一半的行有有效 offset。
    ///
    /// 口径与 `hasUsableLineLevelData` 一致（同样 50% 阈值），
    /// 这样"我们认为可用"与"渲染层认为可用"不会打架。
    static func alreadyHasLineTiming(_ lines: [LyricsLineDto]) -> Bool {
        guard !lines.isEmpty else { return false }
        let timed = lines.filter { ($0.offsetMs ?? 0) > 0 }.count
        return timed * 10 >= lines.count * 5
    }

    /// 是否**任何一行**已经有真实 offset。
    ///
    /// 与 `alreadyHasLineTiming` 的区别很重要：那一档是"够不够渲染层用"（50%），
    /// 这一档是"**有没有真实时间数据**"。只要源真的给了时间轴（哪怕只有零星几行，
    /// 例如坏掉的 LRC），我们就**不该用估算值去覆盖它** —— 那会把"部分准确"
    /// 变成"全部不准确"，反而更差。只有一行都没有时，估算才是纯收益。
    static func hasAnyLineTiming(_ lines: [LyricsLineDto]) -> Bool {
        lines.contains { ($0.offsetMs ?? 0) > 0 }
    }

    /// 返回一份**每一行都有 offset** 的副本。
    ///
    /// - Parameter lines: 原始行。
    /// - Parameter durationMs: 曲目时长（毫秒）。为 nil 时按每行 `fallbackLineMs` 估算。
    /// - Returns: 行数相同、offset 单调递增的副本。
    ///   若原来已经有一半以上的行带 offset，则**原样返回**（不覆盖真实时间轴）。
    static func applying(
        to lines: [LyricsLineDto],
        durationMs: Int?
    ) -> [LyricsLineDto] {
        guard !lines.isEmpty else { return lines }
        guard !alreadyHasLineTiming(lines) else { return lines }

        let weights = lines.map { max($0.content.count, minimumWeight) }
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else { return lines }

        // 总时长：拿不到就用"行数 × 兜底单行时长"估一个，保证 offset 能单调铺开。
        let totalMs = max(durationMs ?? (lines.count * fallbackLineMs), lines.count * minimumLineMs)

        var result: [LyricsLineDto] = []
        result.reserveCapacity(lines.count)

        var accumulatedWeight = 0
        var accumulatedMs = 0
        for (index, line) in lines.enumerated() {
            // 每行起点取"按累计权重算出的位置"与"上一行之后至少 minimumLineMs"
            // 两者中的较大值 —— 前者让整体分布贴合时长，后者保证严格递增。
            let weightedMs = totalMs * accumulatedWeight / totalWeight
            let startMs = max(weightedMs, accumulatedMs)

            var copy = line
            copy.offsetMs = startMs
            result.append(copy)

            accumulatedMs = startMs + minimumLineMs
            accumulatedWeight += weights[index]
        }

        // 末行起点必须落在时长之内，否则会被 Spotify 当成"整首都在未来"。
        if let last = result.last?.offsetMs, last >= totalMs, result.count > 1 {
            result[result.count - 1].offsetMs = max(totalMs - minimumLineMs, 0)
        }

        return result
    }
}
