import Foundation

extension UserDefaults {
    static var container: UserDefaults = .standard
    
    private static let musixmatchTokenKey = "musixmatchToken"
    private static let darkPopUpsKey = "darkPopUps"
    private static let patchTypeKey = "patchType"
    private static let trueShuffleEnabledKey = "trueShuffleEnabled"
    private static let overwriteConfigurationKey = "overwriteConfiguration"
    private static let lyricsColorsKey = "lyricsColors"
    private static let lyricsOptionsKey = "lyricsOptions"
    private static let hasShownCommonIssuesTipKey = "hasShownCommonIssuesTip"
    private static let hasPatchedBootstrapKey = "eeveeHasPatchedBootstrap"
    private static let iconNamePrettifyKey = "iconNamePrettify"
    private static let cleanShareLinksKey = "cleanShareLinks"
    private static let enableLogRecordingKey = "enableLogRecording"
    private static let forcedLyricsPayloadKey = "ngzhwm_forcedLyricsPayload"

    static var musixmatchToken: String {
        get {
            container.string(forKey: musixmatchTokenKey) ?? ""
        }
        set (token) {
            container.set(token, forKey: musixmatchTokenKey)
        }
    }

    static var darkPopUps: Bool {
        get {
            container.object(forKey: darkPopUpsKey) as? Bool ?? true
        }
        set (darkPopUps) {
            container.set(darkPopUps, forKey: darkPopUpsKey)
        }
    }

    static var patchType: EeveePatchType {
        get {
            if let rawValue = container.object(forKey: patchTypeKey) as? Int {
                return EeveePatchType(rawValue: rawValue) ?? .requests
            }

            // If the key is missing (fresh install / "reset data"), default to patching.
            // This avoids users silently falling back to Free tier.
            return .requests
        }
        set (patchType) {
            container.set(patchType.rawValue, forKey: patchTypeKey)
        }
    }

    static var trueShuffleEnabled: Bool {
        get {
            container.object(forKey: trueShuffleEnabledKey) as? Bool ?? false
        }
        set (isEnabled) {
            container.set(isEnabled, forKey: trueShuffleEnabledKey)
        }
    }
    
    static var overwriteConfiguration: Bool {
        get {
            container.bool(forKey: overwriteConfigurationKey)
        }
        set (overwriteConfiguration) {
            container.set(overwriteConfiguration, forKey: overwriteConfigurationKey)
        }
    }
    
    static var hasPatchedBootstrap: Bool {
        get { container.bool(forKey: hasPatchedBootstrapKey) }
        set { container.set(newValue, forKey: hasPatchedBootstrapKey) }
    }

    static var hasShownCommonIssuesTip: Bool {
        get {
            container.bool(forKey: hasShownCommonIssuesTipKey)
        }
        set (hasShownCommonIssuesTip) {
            container.set(hasShownCommonIssuesTip, forKey: hasShownCommonIssuesTipKey)
        }
    }

    /// When true, icon names are prettified: underscores/hyphens become spaces,
    /// camelCase boundaries and numbers get spaces, and parentheses get a leading space.
    static var iconNamePrettify: Bool {
        get {
            container.object(forKey: iconNamePrettifyKey) as? Bool ?? true
        }
        set {
            container.set(newValue, forKey: iconNamePrettifyKey)
        }
    }

    /// When true, the `si` tracking parameter is stripped from shared Spotify links.
    static var cleanShareLinks: Bool {
        get {
            container.object(forKey: cleanShareLinksKey) as? Bool ?? false
        }
        set (cleanShareLinks) {
            container.set(cleanShareLinks, forKey: cleanShareLinksKey)
        }
    }

    /// When true, EeveeSpotify logs content at the debug level and mirrors it into the
    /// exportable eeveespotify_debug.log (ng / Reborn-ng behaviour).
    static var enableLogRecording: Bool {
        get {
            container.bool(forKey: enableLogRecordingKey)
        }
        set {
            container.set(newValue, forKey: enableLogRecordingKey)
        }
    }

    /// **排障开关**：强制替换交出去的歌词 payload，用来把"payload 质量"与
    /// "Spotify 侧门控"这两个变量分开。
    ///
    /// 取值：`""`（关，默认） / `"good"` / `"placeholder"`。
    ///
    /// 为什么要它：**歌词卡片**（与「关于艺人」并列那块）只有 MIMI 的 SECRET 会出现。
    /// 它和失败曲目在 payload 上有两个可见差别 —— 行数（34 vs 3–7）与时间轴真假
    /// （真实 vs 合成）。但"失败曲目 payload 差"和"Spotify 那边就没词"这两件事
    /// 一直是绑在一起的，分不开。
    ///
    /// 这个开关把 payload 变成唯一自变量，**两个方向都要试**（只试一个方向会留下
    /// "伪造的 payload 仍然不够好"这个死角）：
    ///   · `good`        ← 给失败曲目喂 34 行**真实时间轴**；卡片出现 ⇒ payload 是关键
    ///   · `placeholder` ← 给 SECRET 喂 3 行**无时间轴**；卡片消失 ⇒ payload 是关键
    /// 两个方向都不动 ⇒ 门控在 Spotify 侧，payload 无关 ⇒ 转自绘兜底。
    ///
    /// 实现见 `CustomLyrics.x.swift` 的 `loadCustomLyricsForCurrentTrack`：它会**绕开**
    /// 整条取词链和 `toSpotifyLyricsData`，所以「合成行级时间轴」开关对它无效。
    static var forcedLyricsPayload: String {
        get {
            container.string(forKey: forcedLyricsPayloadKey) ?? ""
        }
        set {
            container.set(newValue, forKey: forcedLyricsPayloadKey)
        }
    }
}
