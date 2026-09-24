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

}

// 已移除：`forcedLyricsPayload` 排障开关（连同设置界面的 Picker 与
// `CustomLyrics.x.swift` 里那处短路）。
//
// 移除原因：加入之后出现**稳定复现的启动崩溃**（EXC_BREAKPOINT/SIGTRAP，
// `swift_unexpectedError`，崩在全局 userInitiated 队列上的一个 block 里，
// 我们 dylib 有 4 帧未符号化；两份 .ips 的异常码同一地址 `0x19f2f6f54`）。
// 它挡住了后续所有真机测试，所以先回退，事后再逐一排查。
//
// ⚠️ 但它**已经产出了本轮最重要的结论**，回退不要把结论一起丢掉：
//   · 卡片（与「关于艺人」并列那块）上显示的 provider 是 `EeveeForce…`
//     —— 也就是我们自己写死的名字 ⇒ **卡片是被我们注入的 payload 驱动的**。
//     Spotify 侧的"这首歌有没有词"（`has_lyrics` / 服务端判定 / 本地状态）
//     **不是门控**。
//   · `timeSynchronized = false` 的 payload → **建卡片**；
//     `timeSynchronized = true` → Spotify 走"同步歌词"表现（单行）而**不建卡片**。
//     两个面看起来是**互斥**的。
//   · 推论：「合成行级时间轴」默认开启，正是把卡片挤掉的那个东西。
