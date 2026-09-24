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

// ── 这里曾经有一个"运行时类名探针"（`logPlayerTrackCandidates`）───────────────
//
// 它的目的：离线找出 9.1.x 上到底是哪个类提供 `metadata()`（`has_lyrics` 就在那个
// 字典里），好把 `SPTPlayerTrackHook.targetName` 改成真名。
//
// **已经删掉了**，原因是它连续两次造成启动崩溃，而且一次都没能给出可用结果：
//   · 第一次：挂在「启用日志记录」下面 → 开日志 + 杀后台 + 重开 = 启动后约 291ms
//     崩（EXC_BREAKPOINT/SIGTRAP，栈在 `_CF_forwarding_prep_0` → `swift_getObjectType`，
//     寄存器 `__NSGenericDeallocHandler` = 给已释放对象发消息）；
//   · 第二次：改成独立开关 + 启动后 3 秒 + 只扫白名单前缀，仍然崩（同一崩溃地址
//     0x19dbe54b4、同一份指令流），而且**崩溃时日志文件里什么都没有** ——
//     说明崩在写日志之前，或者日志所在的 tmp 目录随重装被清掉了。
// 结论：在这台设备上"运行时诊断"这条路不可观测也不可控，不值得再试第三次。
//
// 真正需要"哪个类持有 has_lyrics"这个答案时，走离线路线：
//   Tools/eevee-hookfinder/extract_player_track_class.py
// 它直接读解密 IPA 的 `__objc_classname` / `__objc_methname`，不碰运行时，
// 已经据此确认 9.1.86 里 `SPTPlayerTrack` 是存在的（当初 dump-unknown.txt
// 只抓 `_TtC` 开头的 Swift 名，才误判成"不存在"）。

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
