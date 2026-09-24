import Orion
import EeveeSpotifyC
import UIKit
import Foundation
import ObjectiveC.runtime
import os

/// Debug 级统一日志（ng / Reborn-ng 实现）。
/// 受设置里的「启用日志记录」开关控制：关闭时既不写统一日志，也不写导出文件。
private let eeveeLogger = Logger(
    subsystem: "com.eeveespotify",
    category: "debug"
)

private func appendLogFile(_ message: String) {
    let logPath = NSTemporaryDirectory() + "eeveespotify_debug.log"
    let timestamp = Date().description
    let logMessage = "[\(timestamp)] \(message)\n"

    if FileManager.default.fileExists(atPath: logPath) {
        if let fileHandle = FileHandle(forWritingAtPath: logPath) {
            fileHandle.seekToEndOfFile()
            if let data = logMessage.data(using: .utf8) {
                fileHandle.write(data)
            }
            fileHandle.closeFile()
        }
    } else {
        try? logMessage.write(toFile: logPath, atomically: true, encoding: .utf8)
    }
}

func writeDebugLog(_ message: String) {
    guard UserDefaults.enableLogRecording else { return }

    eeveeLogger.debug("\(message, privacy: .public)")
    appendLogFile(message)
}

/// 错误级日志：统一日志走 .error 级（Console 可按 error 过滤），导出文件加 [ERROR] 前缀。
func writeErrorLog(_ message: String) {
    guard UserDefaults.enableLogRecording else { return }

    eeveeLogger.error("\(message, privacy: .public)")
    appendLogFile("[ERROR] \(message)")
}
// Timestamp of tweak initialization — persists across Orion reinits within the same process
// using an environment variable. This prevents the 30s auth window from resetting
// when the C++ timer triggers a session reinit cycle.
let tweakInitTime: Date = {
    if let existing = getenv("EEVEE_BOOT_TIME"),
       let interval = Double(String(cString: existing)) {
        return Date(timeIntervalSince1970: interval)
    }
    let now = Date()
    setenv("EEVEE_BOOT_TIME", "\(now.timeIntervalSince1970)", 1)
    return now
}()

func exitApplication() {
    UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
        exit(EXIT_SUCCESS)
    }
}

// Premium hooks are split so core network/bootstrap patching can stay enabled
// even if certain UI hooks break on a specific Spotify build.
struct PremiumBootstrapGroup: HookGroup { }      // Intercept bootstrap + mutate UCS
struct PremiumUIHooksGroup: HookGroup { }       // UI JSON injections, Siri tweaks, etc.

struct BasePremiumPatchingGroup: HookGroup { }

struct IOS14PremiumPatchingGroup: HookGroup { }
struct NonIOS14PremiumPatchingGroup: HookGroup { }
struct IOS14And15PremiumPatchingGroup: HookGroup { }
struct V91PremiumPatchingGroup: HookGroup { } // For Spotify 9.1.x versions
struct LatestPremiumPatchingGroup: HookGroup { }

// Spotify 9.1.x originally removed the offline helper, so this version family
// skipped the reminder hook entirely. Newer 9.1 builds expose the modern helper
// again. Activate only that hook when its exact Objective-C entry point exists.
func activateV91ServerSidedReminderIfAvailable() {
    let className = ContentOffliningUIHelperImplementationModernHook.targetName
    let selector = Selector((
        "downloadToggledWithCurrentAvailability:addAction:removeAction:pageIdentifier:pageURI:interactionID:"
    ))

    guard let cls = NSClassFromString(className),
          class_getInstanceMethod(cls, selector) != nil else {
        writeDebugLog("[INIT] Server-sided download reminder unavailable on this 9.1.x build")
        return
    }

    LatestPremiumPatchingGroup().activate()
    writeDebugLog("[INIT] Activated server-sided download reminder for 9.1.x")
}

func activatePremiumPatchingGroup() {
    BasePremiumPatchingGroup().activate()
    
    if EeveeSpotify.hookTarget == .lastAvailableiOS14 {
        IOS14PremiumPatchingGroup().activate()
    }
    else if EeveeSpotify.hookTarget == .v91 {
        // 9.1.x versions: Use NonIOS14 hooks but skip offline content hooks
        NonIOS14PremiumPatchingGroup().activate()
        // Only activate if Spotify's UIView category method exists in this build —
        // the method was removed/renamed in 9.1.28 and hooking a missing method is a fatal crash.
        let trackRowsSel = Selector(("initWithViewURI:onDemandSet:onDemandTrialService:trackRowsEnabled:productState:"))
        if UIView.instancesRespond(to: trackRowsSel) {
            V91PremiumPatchingGroup().activate()
        }
    }
    else {
        NonIOS14PremiumPatchingGroup().activate()
        
        if EeveeSpotify.hookTarget == .lastAvailableiOS15 {
            IOS14And15PremiumPatchingGroup().activate()
        }
        else {
            LatestPremiumPatchingGroup().activate()
        }
    }
}

// MARK: - Session protection activation
// Guard each hook group behind runtime checks so minor Spotify updates
// (e.g., 9.1.34 -> 9.1.36) don't crash the app at launch due to
// missing private selectors.
func activateSessionLogoutProtection(minimal: Bool) {
    func log(_ msg: String) {
        NSLog("[EeveeSpotify][SessionProtect] %@", msg)
    }

    @inline(__always)
    func classHasInstanceMethod(_ cls: AnyClass, _ sel: Selector) -> Bool {
        return class_getInstanceMethod(cls, sel) != nil
    }

    if minimal {
        // Only the URLSessionTask hook (used for diagnostics + cancelling revoke endpoints)
        // tends to be stable across minor versions.
        if let cls = NSClassFromString("NSURLSessionTask"), classHasInstanceMethod(cls, #selector(URLSessionTask.resume)) {
            SessionLogoutNetworkHookGroup().activate()
            log("Activated URLSessionTask hooks (minimal)")
        } else {
            log("Skipped URLSessionTask hooks (missing selector)")
        }
        return
    }

    // Auth hooks
    if let cls = NSClassFromString("SPTAuthSessionImplementation") {
        let required: [Selector] = [
            Selector(("logout")),
            Selector(("logoutWithReason:")),
            Selector(("callSessionDidLogoutOnDelegateWithReason:")),
            Selector(("logWillLogoutEventWithLogoutReason:")),
            Selector(("destroy")),
        ]
        let ok = required.allSatisfy { classHasInstanceMethod(cls, $0) }
        if ok {
            SessionLogoutAuthHookGroup().activate()
            log("Activated auth hooks")
        } else {
            log("Skipped auth hooks (missing selector)")
        }
    } else {
        log("Skipped auth hooks (missing class SPTAuthSessionImplementation)")
    }

    // Connectivity hooks
    if let cls = NSClassFromString("_TtC24Connectivity_SessionImpl18SessionServiceImpl") {
        let required: [Selector] = [
            Selector(("automatedLogoutThenLogin")),
            Selector(("userInitiatedLogout")),
            Selector(("sessionDidLogout:withReason:")),
        ]
        let ok = required.allSatisfy { classHasInstanceMethod(cls, $0) }
        if ok {
            SessionLogoutConnectivityHookGroup().activate()
            log("Activated connectivity hooks")
        } else {
            log("Skipped connectivity hooks (missing selector)")
        }
    } else {
        log("Skipped connectivity hooks (missing class SessionServiceImpl)")
    }

    // Ably hooks
    if let cls = NSClassFromString("ARTWebSocketTransport") {
        let required: [Selector] = [
            Selector(("webSocket:didReceiveMessage:")),
            Selector(("webSocket:didFailWithError:")),
        ]
        let ok = required.allSatisfy { classHasInstanceMethod(cls, $0) }
        if ok {
            SessionLogoutAblyHookGroup().activate()
            log("Activated Ably hooks")
        } else {
            log("Skipped Ably hooks (missing selector)")
        }
    } else {
        log("Skipped Ably hooks (missing class ARTWebSocketTransport)")
    }

    // Network hooks
    if let cls = NSClassFromString("NSURLSessionTask"), classHasInstanceMethod(cls, #selector(URLSessionTask.resume)) {
        SessionLogoutNetworkHookGroup().activate()
        log("Activated URLSessionTask hooks")
    } else {
        log("Skipped URLSessionTask hooks (missing selector)")
    }
}

// MARK: - Bootstrap breadcrumbs
@inline(__always)
func eeveeBreadcrumb(_ label: String) {
    let path = NSTemporaryDirectory() + "eeveespotify_boot.txt"
    let ts = Date().description
    let line = "[\(ts)] \(label)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: path), let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

@inline(__always)
func eeveeEnvFlag(_ name: String) -> Bool {
    guard let v = getenv(name) else { return false }
    let s = String(cString: v).lowercased()
    return s == "1" || s == "true" || s == "yes" || s == "y"
}

/// 类名前缀白名单：**先按名字筛，再碰运行时**。
///
/// 这一步不是优化，是**安全措施**。上一版对全部约 1.7 万个类逐个调
/// `class_getInstanceMethod`，真机上表现为"开日志记录 + 杀后台 + 重开"就在启动后
/// 约 291ms 崩（栈：`_CF_forwarding_prep_0` → `swift_getObjectType`，寄存器
/// `__NSGenericDeallocHandler` = 给已释放对象发消息）。
/// 探针只读，但它对每个类都触发 Swift/ObjC 元数据 realize，把启动时序挪了一拍，
/// 点着了 Spotify 恢复上次播放状态时的一个陈旧对象。
/// 加上前缀过滤后，被碰到的类从 ~17000 降到几百，风险回到可接受范围。
///
/// 候选命名空间来自 9.1.86 的符号扫描（`C:\dsh\else\dump-unknown.txt` 的 [classes] 桶）：
/// `SPT*`（老 ObjC 层）、`Player*`、`NowPlaying_*`、`Lyrics_*`、`Stateful*`、`Connect*`。
private let trackProbeNamePrefixes: [String] = [
    "SPT",
    "Player",
    "NowPlaying",
    "Lyrics",
    "Stateful",
    "Connect"
]

/// 探针的启用判据：`UserDefaults.enableTrackProbe`（默认 false）
/// 或环境变量 `EEVEE_TRACK_PROBE=1`。
///
/// ⚠️ **绝不能**再用 `UserDefaults.enableLogRecording` 当条件 —— 那就是上面那次
/// 启动崩溃的成因：日志是日常功能，探针是排障工具。
func eeveeTrackProbeEnabled() -> Bool {
    if UserDefaults.enableTrackProbe { return true }
    return eeveeEnvFlag("EEVEE_TRACK_PROBE")
}

/// 把探针**推到启动之后**再跑。
///
/// 为什么不直接 `async` 一下就好：探针是"想知道类名"时才用的排障工具，
/// 没有任何理由挤在启动窗口里。真机那次崩溃（开日志 + 杀后台 + 重开，启动后约 291ms
/// SIGTRAP）的根因就是它和 Spotify 恢复上次播放状态那段代码抢同一拍主线程。
/// 延迟到启动稳定之后再枚举类表：既拿得到同样的答案，又彻底离开启动路径。
///
/// 延迟期间**不持有**任何 Spotify 对象（只有几个 Int/String），
/// 所以不会像 hook 里那样把宿主 VC 一直留住。
func schedulePlayerTrackProbeIfEnabled() {
    guard eeveeTrackProbeEnabled() else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        logPlayerTrackCandidates()
    }
}

/// 枚举运行时里"同时提供 `metadata` 与 `URI` 的类"，用来定位 9.1.x 上真正的
/// track 类 —— 也就是 `has_lyrics` 覆写应该挂在哪个类上。
///
/// 背景：`CustomLyrics+AllTracksLyrics.swift` 里的 `SPTPlayerTrackHook` 仍然按版本号
/// 猜类名（`EeveeSpotify.hookTarget == .latest ? "SPTPlayerTrackImplementation" : "SPTPlayerTrack"`），
/// 而 9.1.x 被判成 `.v91`，于是它去挂 `SPTPlayerTrack`；可是 9.1.86 的类表里
/// **两个名字都不存在**（`Scripts/dump-spotify-symbols.py` 的 [classes] 桶里搜
/// `PlayerTrack`，只有 `StatefulPlayerTrackPositionImplementation` 等几个无关类）。
/// 那条 hook 一旦绑不上，`has_lyrics = "true"` 就从来没有被写进去过。
///
/// 这个探针只打日志、不改任何行为：日志里出现的那一行就是应该写进 `targetName` 的类名。
/// **默认不跑**，只由 `eeveeTrackProbeEnabled()` 放行（见它的说明）。
func logPlayerTrackCandidates() {
    // `metadata()` / `URI()` 是 track 类在 ObjC 侧已有的两个方法 —— 本仓库的
    // `@objc protocol SPTPlayerTrack` 就是这么声明的。这里不假设任何类名，
    // 直接枚举运行时里"同时实现这两个方法"的类。
    //
    // ⚠️ 注意这个工具链里 `Selector(_:)` 返回的是**非 Optional**（Foundation 的
    // `Selector` 与 `ObjectiveC.Selector` 之间的差异），所以这里不能用
    // `guard let` 绑定，否则编译器直接报"条件绑定的绑定值必须是 Optional"。
    let metadataSelector = Selector(("metadata"))
    let uriSelector = Selector(("URI"))

    for className in ["SPTPlayerTrackImplementation", "SPTPlayerTrack"] {
        writeDebugLog("[TrackProbe] \(className) exists: \(NSClassFromString(className) != nil)")
    }

    // 用 `objc_copyClassList`（不是 `objc_getClassList`）：
    //   · 它一次调用就返回"已注册类"缓冲区的**所有权**，签名干净
    //     （`objc_getClassList` 的缓冲区参数是 `AutoreleasingUnsafeMutablePointer<AnyClass>`，
    //     在"传 nil 拿计数"和"传缓冲区"两种调用上容易踩类型推断的坑）；
    //   · 它返回的是 `AutoreleasingUnsafeMutablePointer<AnyClass>` —— 编译器报错原文
    //     确认了这个类型，而它**不能**直接交给 `free()`。要先
    //     `UnsafeMutableRawPointer(...)` 转成裸指针再 free，这一步是必需的。
    var classCount: UInt32 = 0
    guard let classList = objc_copyClassList(&classCount), classCount > 0 else {
        writeDebugLog("[TrackProbe] objc_copyClassList returned nothing")
        return
    }
    defer { free(UnsafeMutableRawPointer(classList)) }

    var candidates: [String] = []
    var scanned = 0
    for index in 0..<Int(classCount) {
        let cls: AnyClass = classList[index]

        // ① 先取名字（`class_getName` 不触发元数据 realize，代价最低），
        //    名字不在白名单前缀里就直接跳过 —— 绝不碰它的方法表。
        //
        // ⚠️ 这个工具链里 `class_getName` 返回的是**非 Optional** 的
        // `UnsafePointer<CChar>`（和 `Selector(_:)` 一样，跟 SDK 头里的
        // "可为空"声明不一致），所以不能用 `guard let` 绑定 —— 编译器会直接报
        // "条件绑定的值必须是 Optional"。保险起见只判空串。
        let name = String(cString: class_getName(cls))
        guard !name.isEmpty else { continue }
        guard trackProbeNamePrefixes.contains(where: { name.hasPrefix($0) }) else {
            continue
        }

        scanned += 1

        // ② 只对白名单里的类查方法。Swift 里嵌在类内部/闭包里的类型名字很长
        //    （`_TtCFFC24...LyricsViewg9tableView...`），加一个长度上限，
        //    它们都不是我们要找的 track 类。
        guard name.count <= 64 else { continue }
        guard class_getInstanceMethod(cls, metadataSelector) != nil,
              class_getInstanceMethod(cls, uriSelector) != nil else {
            continue
        }
        candidates.append(name)
    }

    writeDebugLog("[TrackProbe] scanned \(scanned) whitelisted class(es); \(candidates.count) expose metadata()+URI(): \(candidates.sorted().joined(separator: ", "))")
}

struct EeveeSpotify: Tweak {
    static let version = "6.6.8"
    static let buildNumber = "2"
    static let repoSlug = GeneratedConfig.repoSlug
    
    static var hookTarget: VersionHookTarget {
        let version = Bundle.main.infoDictionary!["CFBundleShortVersionString"] as! String
        
        NSLog("[EeveeSpotify] Detected Spotify version: \(version)")
        
        switch version {
        case "9.0.48":
            return .lastAvailableiOS15
        case "8.9.8":
            return .lastAvailableiOS14
        case _ where version.contains("9.1"):
            // 9.1.x versions don't have offline content helper classes
            return .v91
        default:
            return .latest
        }
    }
    
    // MARK: - Non-fatal hook error handling
    //
    // Orion's default `handleError(_:)` forwards to `handleErrorDefault(_:)`, which logs
    // and then calls `fatalError`, instantly killing the app. This fires for ANY hook that
    // fails to activate - a missing target class, a renamed/removed selector, a method-add
    // conflict, etc. Critically, this can happen for hooks in `DefaultGroup`
    // (e.g. UIOpenURLContextHook, UIApplicationLiveContainerSharingHook), which Orion
    // activates automatically during its init sequence, BEFORE `EeveeSpotify.init()` runs -
    // so none of the NSClassFromString/selector guards below can protect against it.
    //
    // Since this codebase already treats individual hook groups as independently optional
    // (kill switches, per-group existence checks, "minimal" fallbacks for 9.1.x), a single
    // hook failing to bind on an unexpected Spotify/iOS build should degrade gracefully
    // instead of taking down the whole app. Log it and move on.
    static func handleError(_ error: OrionHookError) {
        let description = error.description
        NSLog("[EeveeSpotify][OrionError] Hook activation failed (non-fatal): %@", description)
        writeDebugLog("[ORION ERROR] \(description)")
        eeveeBreadcrumb("Orion hook activation failed (continuing): \(description)")
        // Deliberately NOT calling handleErrorDefault(error) here - that is what fatalErrors.
    }

    init() {
        eeveeBreadcrumb("Tweak init() entered")
        // Reset per-launch bootstrap state; this MUST NOT persist across restarts.
        // Otherwise Spotify can get stuck on splash because bootstrap is cancelled.
        UserDefaults.hasPatchedBootstrap = false

        // Recovery path for private-class changes: this must run before every
        // manual hook activation, including ad and Premium banner blockers.
        if eeveeEnvFlag("EEVEE_DISABLE_ALL") {
            eeveeBreadcrumb("EEVEE_DISABLE_ALL=1 -> returning without hooks")
            return
        }

        // Local-only premium force. Activated first after the recovery kill-switch,
        // before version gating. Independent of patchType / bootstrap
        // patching / network interception. Keeps premium UI/state even if every
        // other Eevee path is disabled.
        activateEeveePremiumForce()

        activateEeveeCrossfadeForce()

        // TESTING: extended ad blocker (NPV/lyrics ad, home brand-ads, in-stream).
        activateEeveeAdBlockerExtended()

        // Block premium upsell / "Like listening without limits?" popups.
        activateUpsellPopupBlocker()

        // Block the newer Swift service-backed Premium sheets/cards used by
        // Spotify 9.1.x. Each target is runtime-gated for minor-version safety.
        activateUpsellServiceBlocker()

        // Block upsell components injected into Hub/home JSON (e.g. upgrade banners).
        if NSClassFromString("HUBViewModelBuilderImplementation") != nil {
            AdBlockerGroup().activate()
            NSLog("[EeveeSpotify] AdBlockerGroup activated")
        }

        // activateEeveeFlexGesture()

        // Clean Share Links: swizzle the concrete class of UIPasteboard.general in
        // addition to the ClassHook<UIPasteboard> hooks — the general pasteboard is a
        // private subclass whose overridden setters would otherwise bypass base-class
        // swizzles. Installed unconditionally; cleaning is gated per-call by the toggle.
        PasteboardConcreteSwizzler.install()

        // Activate session logout protection first.
        // NOTE: On some Spotify 9.1.x builds, Orion can still crash even if a selector exists
        // (e.g., method type encoding changes). Be conservative for 9.1.x.
        if EeveeSpotify.hookTarget == .v91 {
            // Minimal protection only (safest hook)
            activateSessionLogoutProtection(minimal: true)
        } else {
            activateSessionLogoutProtection(minimal: false)
        }

        let spotifyVersion = Bundle.main.infoDictionary!["CFBundleShortVersionString"] as! String
        let spotifyBuild = Bundle.main.infoDictionary!["CFBundleVersion"] as? String ?? "?"
        let iosVersion = UIDevice.current.systemVersion
        let deviceModel = UIDevice.current.model

        writeDebugLog("=== EeveeSpotify \(EeveeSpotify.version) (build \(EeveeSpotify.buildNumber)) starting ===")
        writeDebugLog("[INIT] Spotify: \(spotifyVersion) (build \(spotifyBuild))")
        writeDebugLog("[INIT] iOS: \(iosVersion), Device: \(deviceModel)")
        writeDebugLog("[INIT] Hook target: \(EeveeSpotify.hookTarget)")
        writeDebugLog("[INIT] Patch type: \(UserDefaults.patchType)")
        writeDebugLog("[INIT] Lyrics source: \(UserDefaults.lyricsSource)")
        writeDebugLog("[INIT] tweakInitTime: \(tweakInitTime)")

        // CarPlay crash fix (Issue #16) — safe-gated
        activateCarPlayCrashFix()

        // （已移除：Reincarnated 自带的开屏捐赠彩蛋 Donation.activate()
        //   —— "Hysan's Elsa Recovery Fund"，第 5/10 次启动弹 toast）

        // Verify critical hook targets exist
        let hookTargets: [(String, String)] = [
            ("SPTAuthSessionImplementation", "SPTAuthSession"),
            ("_TtC24Connectivity_SessionImpl18SessionServiceImpl", "SessionServiceImpl"),
            ("SPTAuthLegacyLoginControllerImplementation", "LegacyLoginController"),
            ("_TtC24Connectivity_SessionImplP33_831B98CC28223E431E21CD27ADD20AF222OauthAccessTokenBridge", "OauthAccessTokenBridge"),
            ("ARTWebSocketTransport", "AblyWebSocket"),
            ("ARTSRWebSocket", "AblySRWebSocket"),
        ]
        var allFound = true
        for (className, label) in hookTargets {
            if NSClassFromString(className) != nil {
                writeDebugLog("[INIT] \(label) class found")
            } else {
                writeDebugLog("[INIT] MISSING class for \(label): \(className)")
                allFound = false
            }
        }
        if allFound {
            writeDebugLog("[INIT] All \(hookTargets.count) hook targets verified")
        }

        // For 9.1.x, activate premium patching and lyrics
        if EeveeSpotify.hookTarget == .v91 {

            // Premium patching (9.1.x)
            // Always activate the *bootstrap interceptor*; it is required for premium patching.
            if UserDefaults.patchType.isPatching {
                PremiumBootstrapGroup().activate()
                writeDebugLog("[INIT] Activated PremiumBootstrapGroup")

                // Optional UI hooks (safe-gated)
                if let hub = NSClassFromString("HUBViewModelBuilderImplementation"),
                   class_getInstanceMethod(hub, Selector(("addJSONDictionary:"))) != nil {
                    PremiumUIHooksGroup().activate()
                } else {
                    writeDebugLog("[INIT] Skipped PremiumUIHooksGroup (missing HUBViewModelBuilderImplementation/addJSONDictionary:)")
                }

                activateV91ServerSidedReminderIfAvailable()
            }

            let lyricsEnabled = UserDefaults.lyricsSource.isReplacingLyrics

            // Lyrics hooks (guarded)
            if lyricsEnabled {
                let fullscreenOK: Bool = {
                    // For 9.1.x, targetName resolves to Lyrics_FullscreenElementPageImpl.FullscreenElementViewController
                    if let cls = NSClassFromString("Lyrics_FullscreenElementPageImpl.FullscreenElementViewController") {
                        return class_getInstanceMethod(cls, #selector(UIViewController.viewDidLoad)) != nil
                    }
                    return false
                }()

                let npvOK: Bool = {
                    if let cls = NSClassFromString("NowPlaying_ScrollImpl.NPVScrollViewController") {
                        return class_getInstanceMethod(cls, #selector(UIViewController.viewWillAppear(_:))) != nil
                            && class_getInstanceMethod(cls, #selector(UIViewController.viewWillDisappear(_:))) != nil
                    }
                    return false
                }()

                // ng 的歌词分组：Base（全屏宿主 / 表格修复）+ Modern（NPV 宿主 + 全屏逐词）。
                // 指向 9.1.74 已消失类的 hook 由 handleError 非致命跳过。
                if fullscreenOK || npvOK {
                    BaseLyricsGroup().activate()
                    ModernLyricsGroup().activate()
                    writeDebugLog("[INIT] Activated ng lyrics groups (Base+Modern)")
                } else {
                    writeDebugLog("[INIT] Skipped ng lyrics groups (no lyrics host on this build)")
                }

                // 定位"has_lyrics 应该写进哪个类"：**默认不跑**，而且**推到启动之后**跑。
                //
                // ⚠️ 这里以前写的是 `if UserDefaults.enableLogRecording { logPlayerTrackCandidates() }`，
                // 真机上导致"开日志记录 + 杀后台 + 重开"必崩（启动后约 291ms，
                // SIGTRAP 在消息转发里）。日志是日常功能，探针是排障工具，两者不能共用开关；
                // 而且探针本来就不该挤在启动窗口里 —— 见 `schedulePlayerTrackProbeIfEnabled`。
                schedulePlayerTrackProbeIfEnabled()
            }

            // Settings integration (guarded)
            if let cls = NSClassFromString("ProfileSettingsSection"),
               class_getInstanceMethod(cls, Selector(("numberOfRows"))) != nil,
               class_getInstanceMethod(cls, Selector(("didSelectRow:"))) != nil,
               class_getInstanceMethod(cls, Selector(("cellForRow:"))) != nil {

                UniversalSettingsIntegrationProfileGroup().activate()

                if NSClassFromString("SettingsViewController") != nil {
                    UniversalSettingsIntegrationSettingsVCGroup().activate()
                }
                // RootSettingsViewController was removed in some 9.1.x builds (9.1.36).
                // Only activate if the class exists.
                if NSClassFromString("RootSettingsViewController") != nil {
                    UniversalSettingsIntegrationRootSettingsVCGroup().activate()
                }
                // UINavigationController exists; this hook is generic and safe.
                UniversalSettingsIntegrationNavGroup().activate()

            } else {
                writeDebugLog("[INIT] Skipped settings integration (ProfileSettingsSection API mismatch)")
            }

            // 9.1.44 path — ProfileSettingsSection gone, new SettingsListViewController owns Settings root.
            if NSClassFromString("_TtC21Settings_PlatformImpl26SettingsListViewController") != nil {
                UniversalSettingsIntegrationListVCGroup().activate()
                writeDebugLog("[INIT] Activated SettingsListViewController hook (9.1.44 path)")
            } else {
                writeDebugLog("[INIT] Settings_PlatformImpl.SettingsListViewController missing")
            }
            NSLog("[EeveeSpotify] Initialization complete for 9.1.x")
            TrueShuffleHook.install()
            activateSponsorBlock()
            return
        }

        // For other versions, activate all features normally
        if UserDefaults.experimentsOptions.showInstagramDestination {
            InstgramDestinationGroup().activate()
        }
        
        if UserDefaults.darkPopUps {
            DarkPopUps().activate()
        }
        
        if UserDefaults.patchType.isPatching {
            activatePremiumPatchingGroup()
        }
        
        if UserDefaults.lyricsSource.isReplacingLyrics {
            BaseLyricsGroup().activate()
            
            if EeveeSpotify.hookTarget == .latest {
                ModernLyricsGroup().activate()
            }
            else {
                LegacyLyricsGroup().activate()
            }
        }
        
        // Always activate settings integration (except for 9.1.x which exits early above)
        UniversalSettingsIntegrationProfileGroup().activate()
        UniversalSettingsIntegrationSettingsVCGroup().activate()
        if NSClassFromString("RootSettingsViewController") != nil {
            UniversalSettingsIntegrationRootSettingsVCGroup().activate()
        }
        if NSClassFromString("_TtC21Settings_PlatformImpl26SettingsListViewController") != nil {
            UniversalSettingsIntegrationListVCGroup().activate()
        }
        UniversalSettingsIntegrationNavGroup().activate()
        SettingsIntegrationGroup().activate()

        // These were previously only activated in the 9.1.x branch above
        // (before its early `return`) — meaning karaoke, SponsorBlock, and
        // the debug probes never ran at all on the current/latest Spotify
        // version, only on 9.1.x installs. Each of these functions already
        // self-guards internally on its own enabled/feature flags (see
        // activateSponsorBlock's `opts.enabled` check, for example), so
        // it's safe to call them unconditionally here too.
        activateSponsorBlock()
    }
}
