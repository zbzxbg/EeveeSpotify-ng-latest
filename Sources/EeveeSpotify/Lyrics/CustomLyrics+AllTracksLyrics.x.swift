import Orion
import UIKit

private var shouldOverrideLocalTrackURI = false

class SPTPlayerTrackHook: ClassHook<NSObject> {
    typealias Group = BaseLyricsGroup
    static let targetName = EeveeSpotify.hookTarget == .latest
        ? "SPTPlayerTrackImplementation"
        : "SPTPlayerTrack"

    func metadata() -> [String: String] {
        var meta = orig.metadata()
        meta["has_lyrics"] = NgzhwmSettingsViewModel.isLyricsFeatureDisabled ? "false" : "true"
        return meta
    }
    
    func URI() -> NSURL? {
        let uri = orig.URI()
        
        guard shouldOverrideLocalTrackURI,
              let absoluteString = uri?.absoluteString,
              absoluteString.isLocalTrackIdentifier else {
            return uri
        }

        writeDebugLog("[Lyrics] Overriding local track URI → spotify:track:")
        return NSURL(string: "spotify:track:")!
    }
}

class LyricsScrollProviderHook: ClassHook<NSObject> {
    // 9.1.x 上 `Lyrics_NPVCommunicatorImpl.ScrollProvider` 已不存在（真机日志 targetNotFound），
    // 挪进永不激活的隔离组，避免注册期崩掉注入工具。
    typealias Group = V91UnavailableLyricsGroup
    static var targetName = HookTargetNameHelper.lyricsScrollProvider
    
    func isEnabledForTrack(_ track: SPTPlayerTrack) -> Bool {
        return !NgzhwmSettingsViewModel.isLyricsFeatureDisabled
    }
}

/// 内嵌（预览）歌词的逐词宿主查找器。
///
/// 背景：ng 原来靠 `LyricsWordByWordModernHostHook` 直接 hook
/// `Lyrics_NPVCommunicatorImpl.LyricsOnlyViewController` 拿内嵌歌词 VC；
/// 该类在 9.1.x 上已被移除（9.1.76 主二进制类名扫描：整个二进制里都不存在
/// `LyricsOnlyViewController`；真机日志 targetNotFound）。
///
/// 为什么不再「换个 targetName 重新 hook」：Orion 在**注册期**解析不到目标类/方法时
/// 会走错误路径 —— 在 App 里只是一条日志，但在注入工具进程里加载同一个 dylib 时
/// 会直接 SIGTRAP 把工具崩掉（已实测：官方 dylib 能注入、我们的一注入就闪退）。
/// 因此这里**不新增任何 hook**，改为在已经绑定成功的 NPV 宿主里用纯 UIKit 遍历查找；
/// 最坏情况只是「没找到、没效果」，不会引入新的注册期崩溃。
///
/// 候选类名来自 9.1.76 主二进制扫描（`Lyrics_TextElementImpl` /
/// `Lyrics_TextComponentImpl` / `Lyrics_NPVElementsKitImpl` 三个模块）；
/// 真机日志里 statefulPlayer 也会以 `LyricsTextElementService` 特征串被取出，
/// 与「内嵌歌词由这套组件渲染」一致。
enum InlineLyricsHostLocator {
    private static let viewControllerCandidates: [String] = [
        "Lyrics_TextComponentImpl.LyricsViewControllerImplementation",
    ]

    private static let viewCandidates: [String] = [
        "Lyrics_TextElementImpl.LyricsTextElementUI",
        "Lyrics_TextElementImpl.LyricsTextView",
        "Lyrics_TextElementImpl.LyricsLabelsView",
        "Lyrics_NPVElementsKitImpl.LyricsViewElementUI",
    ]

    static func scheduleLookup(from root: UIViewController?) {
        guard let root else { return }
        // 让布局先跑一拍，VC 层级与视图都在位了再找。
        DispatchQueue.main.async { lookup(from: root) }
    }

    private static func lookup(from root: UIViewController) {
        guard NgzhwmSettingsViewModel.isWordByWordLyricsEnabled else { return }
        guard let host = findHost(from: root) else {
            writeDebugLog("[WordByWord] inline host not found (9.1.x candidates absent)")
            return
        }

        writeDebugLog("[WordByWord] inline host found: \(NSStringFromClass(type(of: host)))")
        onMainThreadSync {
            WordByWordHost.shared.rememberInlineController(host)
            WordByWordHost.shared.attach(to: host, showsTranslation: false)
        }
    }

    /// 先找 VC 候选（含子 VC 与 present 链），命中的视图候选则沿 responder 链上溯到所属 VC。
    private static func findHost(from root: UIViewController) -> UIViewController? {
        var queue: [UIViewController] = [root]
        var visited = 0
        while !queue.isEmpty && visited < 64 {
            let vc = queue.removeFirst()
            visited += 1
            if viewControllerCandidates.contains(NSStringFromClass(type(of: vc))) { return vc }
            if let viaView = viewHost(in: vc.view) { return viaView }
            queue.append(contentsOf: vc.children)
            if let presented = vc.presentedViewController { queue.append(presented) }
        }
        return nil
    }

    private static func viewHost(in root: UIView?) -> UIViewController? {
        guard let root else { return nil }
        var queue: [UIView] = [root]
        var visited = 0
        while !queue.isEmpty && visited < 2000 {
            let view = queue.removeFirst()
            visited += 1
            if viewCandidates.contains(NSStringFromClass(type(of: view))) {
                var responder: UIResponder? = view
                while let current = responder {
                    if let vc = current as? UIViewController { return vc }
                    responder = current.next
                }
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }
}

class NPVScrollViewControllerHook: ClassHook<NSObject> {
    typealias Group = ModernLyricsGroup
    static var targetName = "NowPlaying_ScrollImpl.NPVScrollViewController"

    func viewWillAppear(_ animated: Bool) {
        shouldOverrideLocalTrackURI = true
        writeDebugLog("[Lyrics] NPV scroll — enabling local track URI override")
        orig.viewWillAppear(animated)

        // 9.1.x 上内嵌歌词宿主已改名，改为运行时查找（不新增 hook，避免注册期崩溃）。
        InlineLyricsHostLocator.scheduleLookup(from: target as? UIViewController)
    }
    
    func viewWillDisappear(_ animated: Bool) {
        shouldOverrideLocalTrackURI = false
        orig.viewWillDisappear(animated)
    }
}

class NowPlayingScrollViewControllerHook: ClassHook<NSObject> {
    typealias Group = LegacyLyricsGroup
    static var targetName = "NowPlaying_ScrollImpl.NowPlayingScrollViewController"
    
    func nowPlayingScrollViewModelWithDidLoadComponentsFor(
        _ track: SPTPlayerTrack,
        withDifferentProviders: Bool,
        scrollEnabledValueChanged: Bool
    ) -> NowPlayingScrollViewController {
        let controller = orig.nowPlayingScrollViewModelWithDidLoadComponentsFor(
            track,
            withDifferentProviders: withDifferentProviders,
            scrollEnabledValueChanged: scrollEnabledValueChanged
        )
        
        if !scrollEnabledValueChanged {
            controller.scrollEnabled = true
            controller.nowPlayingScrollViewModelDidChangeScrollEnabledValue()
        }
        
        return controller
    }
}
