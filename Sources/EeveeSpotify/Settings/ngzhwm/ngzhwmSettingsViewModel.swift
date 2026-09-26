import Foundation
import Combine

class NgzhwmSettingsViewModel: ObservableObject {
    static let removeMxmInterludeSymbolKey = "ngzhwm_removeMxmInterludeSymbol"
    static let disableLyricsFeatureKey = "ngzhwm_disableLyricsFeature"
    static let neteaseRomajiLocalKey = "ngzhwm_neteaseRomajiLocal"
    static let neteaseHideTranslationKey = "ngzhwm_neteaseHideTranslation"
    static let wordByWordLyricsKey = "ngzhwm_wordByWordLyrics"
    static let betterWordByWordLyricsKey = "ngzhwm_betterWordByWordLyrics"
    // 已移除 `amllPreferredKey`（2026-09-25）：「AMLL 优先」整条链去掉，
    // AMLL 仍是来源选择器里的普通来源。
    /// 「给无时间轴的歌词补时间轴」—— 见 `isSyntheticLineTimingEnabled`。
    ///
    /// ⚠️ 2026-09-26 **恢复为真开关**（曾一度写死启用）：需要它来验证
    /// "不补时间轴时这份 payload 还能不能正常展示"。沿用旧 key 名，
    /// 设备上残留的值会被重新读起来。
    static let syntheticLineTimingKey = "ngzhwm_syntheticLineTiming"
    // 已移除两个 key（2026-09-25）：`ngzhwm_hideOfficialLyrics` /
    // `ngzhwm_injectLyricsCardElement` —— 它们对应的行为已在下面**写死启用**，
    // 不再读 UserDefaults。旧设备上残留的键不再被读、也不会被清（留着无害）。
    static let blurredLyricsBackdropKey = "ngzhwm_blurredLyricsBackdrop"
    static let lyricsBackdropMaterialKey = "ngzhwm_lyricsBackdropMaterial"

    static var isLyricsFeatureDisabled: Bool {
        UserDefaults.standard.bool(forKey: disableLyricsFeatureKey)
    }

    /// 设备主语言是否为中文（简体/繁体）。
    static var isChineseDevice: Bool {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true
    }

    /// 读取带默认值的布尔开关：key 尚未写入时返回 defaultValue，否则返回已存值。
    private static func bool(forKey key: String, defaultValue: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil
            ? defaultValue
            : UserDefaults.standard.bool(forKey: key)
    }

    static var isWordByWordLyricsEnabled: Bool {
        bool(forKey: wordByWordLyricsKey, defaultValue: true)
    }

    static var isNeteaseHideTranslationEnabled: Bool {
        bool(forKey: neteaseHideTranslationKey, defaultValue: !isChineseDevice)
    }

    // 已移除 `isAmllPreferred`（2026-09-25，用户反馈"感觉没什么用"）。
    // 它原本做的事：先向 AMLL 要逐词歌词，不合格再回退到用户选的那个源。
    // 现在 AMLL 只是来源选择器里的一个普通来源，选它就只查它。

    /// 「隐藏 Spotify 官方歌词」：我方来源取不到词时，**不再把 Spotify 的原始响应放行**，
    /// 而是用我们自己的一小段「未找到歌词」占位顶上去。
    ///
    /// 为什么需要：钩子在取词失败时原本是 `customLyricsData ?? buffer`，于是界面上显示的是
    /// **Spotify 自己的歌词** —— 日区那批的来源写着「プチリリ」（Spotify 的日文歌词供应商，
    /// **不带 (EeveeSpotify) 后缀**），而且不会跟着我们的罗马化设置走，
    /// 看起来就像"来源设置没生效 / 罗马化设置失效"。
    ///
    /// ⚠️ **写死为 true**（2026-09-25）：这已经是修好的行为，不再是可选项 ——
    /// 用户选定了某个来源，预期就是"要么显示这个来源的词，要么什么都不显示"，
    /// 而不是"取不到就悄悄换成 Spotify 的"。
    /// 想明确看官方歌词的模式仍然在：来源里选「禁用歌词替换」（`.notReplaced`）。
    static var isOfficialLyricsHidden: Bool { true }

    /// 「模糊封面背景」是否生效。
    ///
    /// **不再是独立开关**：需求是"更好的逐词歌词启用时，这两个背景功能就跟着启用"，
    /// 所以它直接派生自 `isBetterWordByWordLyricsEnabled`。
    /// 既有的 `blurredLyricsBackdropKey` 不再参与判断（保留 key 常量与 VM 属性只是为了
    /// 不破坏旧数据、少一处无谓改动）。
    static var isLyricsBlurredBackdropEnabled: Bool {
        isBetterWordByWordLyricsEnabled
    }

    /// 「更好的逐词歌词」：Apple Music 风格的独立渲染层（需 iOS 26+）。
    ///
    /// 默认**关闭** —— 这是整体重写，先让用户显式开启；出问题一键回到旧实现。
    static var isBetterWordByWordLyricsEnabled: Bool {
        bool(forKey: betterWordByWordLyricsKey, defaultValue: false)
    }

    /// 是否在模糊封面之上再叠一层系统材质压色带。
    /// 与 `isLyricsBlurredBackdropEnabled` 同理，跟随「更好的逐词歌词」。
    static var isLyricsBackdropMaterialEnabled: Bool {
        isBetterWordByWordLyricsEnabled
    }

    /// 「给无时间轴的歌词补时间轴」：Genius 这类源给的是纯文本（`timeSynced: false`），
    /// 在这个版本上会被渲染层判为"不可用"，表现就是**歌词模块不出现**。
    ///
    /// 开启后，注入给 Spotify 的那份 payload 会被铺上一层按曲目时长估算的行级时间轴，
    /// 从而走"同步歌词"渲染路径。**只影响注入给 Spotify 的 protobuf**，
    /// `currentLyricsDto` 与逐词 overlay 的判据都不变。
    ///
    /// ⚠️ 2026-09-26 **恢复为真开关**（此前一度写死 `true`）。默认 **ON** ——
    /// 保持"Genius 这类纯文本源也能出歌词模块"的既有行为不变；
    /// 关掉它用于验证"不补时间轴时这份 payload 还能不能正常展示"。
    static var isSyntheticLineTimingEnabled: Bool {
        bool(forKey: syntheticLineTimingKey, defaultValue: true)
    }

    /// 「给没有歌词卡片的曲目补一个卡片元素」。`Bool` 语义：**恒为启用**。
    ///
    /// 背景：真机取证发现 `scrollsita/v1/scroll/spotify:track:<id>`（正在播放页的**元素列表**）
    /// 只在"Spotify 自己有官方歌词"的曲目上多下发一个元素（内层字段号 5，只引用曲目 URI）。
    /// 三首样本 100% 吻合，而唯一一次肉眼看到歌词卡片正是那首有多下发元素的曲目。
    ///
    /// 补上之后，缺这一项的响应会被写入这一项（byte 级，只在能完整解析时动手，
    /// 任何异常都原样放行）。见 `ScrollsitaLyricsElementInjector`。
    ///
    /// ⚠️ **写死为 true**（2026-09-25）：假设已在真机验证（补上后卡片出现、内容来自我们注入的
    /// payload），因此不再是实验开关 —— 否则"某些歌没有歌词卡片"会随这个开关的默认值回归。
    static var isLyricsCardElementInjectionEnabled: Bool { true }
}
