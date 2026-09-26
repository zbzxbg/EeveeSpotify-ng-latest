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
    /// 「给没有歌词卡片的曲目补一个卡片元素」—— 见 `isLyricsCardElementInjectionEnabled`。
    ///
    /// ⚠️ 2026-09-26 **恢复为真开关**（曾一度写死启用）：2026-09-26 的真机日志（日志 3）
    /// 显示这个元素在部分曲目上渲染成了「即将发布 / 已预收藏」卡，需要 A/B 才能定性。
    /// 沿用旧 key 名，设备上残留的值会被重新读起来。
    static let injectLyricsCardElementKey = "ngzhwm_injectLyricsCardElement"
    /// 「把服务端那条 `lyrics_entry_point_enabled` 钉成 true」—— 见 `isLyricsEntryPointFlagForced`。
    ///
    /// ⚠️ 2026-09-26 由**写死**改为真开关：真机 A/B 已经排除了「补卡片元素」那一处
    /// （关掉它之后那张过期的「即将发布」卡**依然出现**），于是剩下的、唯一还能影响
    /// 正在播放页卡片渲染的我们自家改动就是这条 flag。留开关就是为了判定它。
    static let lyricsEntryPointFlagKey = "ngzhwm_lyricsEntryPointFlag"
    /// 「屏蔽正在播放页的预热卡」—— 见 `isNowPlayingPrereleaseProviderDisabled`。
    ///
    /// 2026-09-26 新增：解密二进制把"假卡"钉成了
    /// `Prerelease.UI.PrereleaseCardNowPlaying` + 正在播放页专用的 prerel provider，
    /// 于是终于有一个"既碰得到、又在正确的层"的落点。默认 OFF（不改既有行为）。
    static let nowPlayingPrereleaseProviderKey = "ngzhwm_disableNpvPrereleaseProvider"
    // 已移除一个 key（2026-09-25）：`ngzhwm_hideOfficialLyrics` ——
    // 它对应的行为已在下面**写死启用**，不再读 UserDefaults。
    // 旧设备上残留的键不再被读、也不会被清（留着无害）。
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

    /// 「给没有歌词卡片的曲目补一个卡片元素」。
    ///
    /// 背景：真机取证发现 `scrollsita/v1/scroll/spotify:track:<id>`（正在播放页的**元素列表**）
    /// 只在"Spotify 自己有官方歌词"的曲目上多下发一个元素（内层字段号 5，只引用曲目 URI）。
    /// 补上之后，缺这一项的响应会被写入这一项（byte 级，只在能完整解析时动手，
    /// 任何异常都原样放行）。见 `ScrollsitaLyricsElementInjector`。
    ///
    /// ⚠️ 2026-09-26 **恢复为真开关**（此前一度写死 `true`）。默认 **ON** ——
    /// 保持"404 曲目也有歌词卡片"的既有行为不变。
    ///
    /// 为什么要留开关：日志 3 解出的元素清单显示，在 404 曲目上我们补的这一个元素
    /// 是那份响应里**唯一**多出来的东西，而用户报告这些曲目上会间歇出现一张
    /// 「即将发布 / 已预收藏」卡（日期早已过期，甚至有 2021 年的）。
    /// 关掉它即可判定：那张卡到底是这个元素渲出来的，还是另一条路来的。
    static var isLyricsCardElementInjectionEnabled: Bool {
        bool(forKey: injectLyricsCardElementKey, defaultValue: true)
    }

    /// 是否把服务端下发的 `lyrics_entry_point_enabled`（scope `ios-feature-lyrics`）钉成 true。
    ///
    /// 默认 **ON** —— 保持"9.1.86 上歌词卡片能出现"的既有行为不变。
    ///
    /// 为什么要留开关（2026-09-26）：排查那张**日期早已过期**的「即将发布 / 已预收藏」卡。
    /// 三条路已经排掉了两条：
    ///   · **元素列表** —— 假卡出现在原生只有 `[2,3,4]`、连 `12`（正版预热卡）都没有的曲目上；
    ///   · **补卡片元素**（`isLyricsCardElementInjectionEnabled`）—— 真机关掉它，假卡**照样出现**；
    ///   · **HTTP 数据** —— 九份日志里没有任何一条响应带着预热 / 发行日期，
    ///     连 metadata / entity 类接口都不存在，那份数据 100% 在客户端本地。
    ///
    /// ⇒ 我们唯一还可能"让客户端多渲染一张卡"的就是这条 flag。关掉它即可判定：
    /// 假卡消失 = 是它；假卡还在 = 与我们无关，那是 Spotify 自己拿着过期的专辑
    /// prerelease 记录渲出来的。
    static var isLyricsEntryPointFlagForced: Bool {
        bool(forKey: lyricsEntryPointFlagKey, defaultValue: true)
    }

    /// 「屏蔽正在播放页的预热卡（整个 provider）」—— 见 `isNowPlayingPrereleaseProviderDisabled`。
    ///
    /// 默认 **ON**（2026-09-26 由 OFF 改成 ON）：
    ///
    ///   · 这个 bug 是**偶发/竞态**（用户原话："可能这首歌有，可能那首歌有"），
    ///     按歌复现不了 ⇒ 不该让用户自己去撞、也不该把"别再出现"做成一个要自己去打开的开关；
    ///   · 实际落点是 `PrereleaseNPVProviderRegistrationHook`：拦
    ///     `…NowPlayingViewProviderServiceImpl.registerScrollProviderIn:`，
    ///     开关开着就**不注册**这一族 provider。之所以不用服务端 flag，
    ///     是因为日志 13 已经证明 `ios-prerelease-nowplayingviewprovider-impl.is_enabled`
    ///     **不是闸**（钉成 false 也照样出卡）。
    ///
    /// 代价明说：**正在播放页的任何预热卡都会消失**（包括"真的"那张）；
    /// 专辑页 / 关注页 / 搜索页那些 prerel 表面不受影响 —— 它们的 provider 不走这条注册。
    /// 设置页里仍留开关：想要真预热卡的人可以自己关掉。
    static var isNowPlayingPrereleaseProviderDisabled: Bool {
        bool(forKey: nowPlayingPrereleaseProviderKey, defaultValue: true)
    }
}
